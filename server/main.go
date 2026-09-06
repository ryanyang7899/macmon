// macmon-server: 远程监控数据接收/存储/看板服务器
//
// 纯标准库, 零第三方依赖。编译成单二进制, 跑在任意 Linux/macOS。
//
// 环境变量:
//   PORT          监听端口          (默认 8080)
//   DATA_DIR      数据目录          (默认 ./data)
//   WEB_PASSWORD  看板登录密码      (默认空=不鉴权, 生产环境必须设置)
//   MACMON_DEVICES 预配设备 "name=token;name2=token2" (默认空=接受任意 token, 开发用)
//   RETENTION_DAYS 历史保留天数     (默认 1, 首次启动的种子; 之后以管理页面设置 + settings.json 为准)
//
// 接口:
//   POST /api/metrics            Agent 推送 (Bearer token; 待注册码首推自动注册)
//   POST /api/register           共享注册码换 token (SETUP_KEY)
//   GET  /api/devices            设备列表 (需要看板密码)
//   GET  /api/unregistered       未注册设备 (需要看板密码)
//   POST /api/pending-code       生成逐设备注册码 (需要看板密码)
//   DELETE /api/pending-code     作废注册码 (需要看板密码)
//   POST /api/clear-unregistered 清空未注册列表 (需要看板密码)
//   GET  /api/setup-key          共享注册码 (需要看板密码)
//   POST /api/device/delete      注销/删除设备 (需要看板密码)
//   POST /api/device/rename      重命名设备 (需要看板密码)
//   POST /api/device/rotate-token 轮换设备 token (需要看板密码)
//   POST /api/device/suspend     禁用/启用设备 (需要看板密码)
//   GET  /api/monitor/devices    设备列表脱敏 (agent token)
//   POST /api/monitor/snapshots  批量最新快照 (agent token)
//   GET  /api/latest?device=xx   最新快照 (需要看板密码)
//   GET  /api/history?device=xx&hours=24&paths=cpu.usage,cpu.temp  历史序列
//   GET  /                        看板页面 (静态文件)

package main

import (
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

// ---------- 存储 ----------

type Store struct {
	mu            sync.Mutex
	dir           string
	devices       map[string]Device        // deviceID -> 设备信息
	tokenToDevice map[string]string        // token -> deviceID
	pending       map[string]*PendingDevice // ip|name -> 未注册设备
	codes         map[string]PendingCode    // 注册码 -> 绑定信息
	retentionDays int
}

type Device struct {
	Name      string `json:"name"`
	Token     string `json:"token"`
	FirstSeen int64  `json:"first_seen"`
	LastSeen  int64  `json:"last_seen"`
	IP        string `json:"ip"`
	Suspended bool   `json:"suspended"`
}

// 未注册设备: 生产模式下发送过推送但 token 未识别, 记录来源供管理员审批
type PendingDevice struct {
	Name      string `json:"name"`
	IP        string `json:"ip"`
	FirstSeen int64  `json:"first_seen"`
	LastSeen  int64  `json:"last_seen"`
	Count     int64  `json:"count"`
}

// 逐设备注册码: 生成后填入 Agent 配置的 token 字段, 首条推送自动完成注册
type PendingCode struct {
	Code      string `json:"code"`
	Device    string `json:"device"`
	ExpiresAt int64  `json:"expires_at"`
}

// 安全化 deviceID, 用作目录/文件名
func safeID(s string) string {
	re := regexp.MustCompile(`[^a-zA-Z0-9._-]`)
	return re.ReplaceAllString(s, "_")
}

func NewStore(dir string, retentionDays int) (*Store, error) {
	s := &Store{
		dir:           dir,
		devices:       map[string]Device{},
		tokenToDevice: map[string]string{},
		pending:       map[string]*PendingDevice{},
		codes:         map[string]PendingCode{},
		retentionDays: retentionDays,
	}
	if err := os.MkdirAll(filepath.Join(dir, "history"), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dir, "latest"), 0o755); err != nil {
		return nil, err
	}
	// 留存天数优先级: settings.json (运行期事实来源) > env RETENTION_DAYS > 默认 1 天
	if n, ok := s.loadSettings(); ok {
		s.retentionDays = n
	} else if s.retentionDays <= 0 {
		s.retentionDays = 1
	}
	// 加载设备表
	devFile := filepath.Join(dir, "devices.json")
	if data, err := ioutil.ReadFile(devFile); err == nil {
		var list []Device
		if json.Unmarshal(data, &list) == nil {
			for _, d := range list {
				s.devices[d.Name] = d
				s.tokenToDevice[d.Token] = d.Name
			}
		}
	}
	// 加载未注册设备
	if data, err := ioutil.ReadFile(filepath.Join(dir, "unregistered.json")); err == nil {
		var list []*PendingDevice
		if json.Unmarshal(data, &list) == nil {
			for _, p := range list {
				if p != nil {
					s.pending[p.IP+"|"+p.Name] = p
				}
			}
		}
	}
	// 加载注册码
	if data, err := ioutil.ReadFile(filepath.Join(dir, "codes.json")); err == nil {
		var list []PendingCode
		if json.Unmarshal(data, &list) == nil {
			for _, c := range list {
				s.codes[c.Code] = c
			}
		}
	}
	// 清理过期历史
	s.cleanupOldFiles()
	return s, nil
}

// 预配设备 (env MACMON_DEVICES), 返回注册的设备名集合
func (s *Store) provisionDevices(spec string) []string {
	var names []string
	for _, pair := range strings.Split(spec, ";") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) != 2 {
			continue
		}
		name, token := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
		if name == "" || token == "" {
			continue
		}
		// 预配只作为"种子": 仅当该 token 尚未映射到其他设备时才生效。
		// 设备已改名时, 重启不得把 token 映射重置回预配名 (否则僵尸条目反复复活)
		if _, exists := s.tokenToDevice[token]; !exists {
			if _, ok := s.devices[name]; !ok {
				s.devices[name] = Device{Name: name, Token: token}
			}
			s.tokenToDevice[token] = name
			names = append(names, name)
		}
	}
	return names
}

func (s *Store) saveDevices() {
	s.mu.Lock()
	defer s.mu.Unlock()
	var list []Device
	for _, d := range s.devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	if data, err := json.MarshalIndent(list, "", "  "); err == nil {
		_ = ioutil.WriteFile(filepath.Join(s.dir, "devices.json"), data, 0o644)
	}
}

func (s *Store) deviceByToken(token string) (Device, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	name, ok := s.tokenToDevice[token]
	if !ok {
		return Device{}, false
	}
	d, ok := s.devices[name]
	return d, ok
}

func (s *Store) deviceByName(name string) (Device, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[name]
	return d, ok
}

func (s *Store) touchDevice(d Device, ip string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d.LastSeen = time.Now().Unix()
	d.IP = ip
	s.devices[d.Name] = d
	s.saveDevicesUnlocked()
}

func (s *Store) allDevices() []Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := []Device{}
	for _, d := range s.devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	return list
}

func (s *Store) saveDevicesUnlocked() {
	var list []Device
	for _, d := range s.devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	if data, err := json.MarshalIndent(list, "", "  "); err == nil {
		_ = ioutil.WriteFile(filepath.Join(s.dir, "devices.json"), data, 0o644)
	}
}

// ---------- 设备注册 ----------

// 从待注册列表移除指定设备名 (调用方须持锁)
func (s *Store) removePendingByNameLocked(name string) {
	for k, p := range s.pending {
		if p.Name == name {
			delete(s.pending, k)
		}
	}
}

// 注册/复用设备, 返回 token。同名设备视为重装, 复用原 token。
func (s *Store) registerDevice(name string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if d, ok := s.devices[name]; ok {
		return d.Token, nil
	}

	token, err := randomToken()
	if err != nil {
		return "", err
	}
	s.devices[name] = Device{Name: name, Token: token, FirstSeen: time.Now().Unix()}
	s.tokenToDevice[token] = name
	s.removePendingByNameLocked(name)
	s.saveDevicesUnlocked()
	s.saveUnregisteredUnlocked()
	return token, nil
}

// 开发模式: 按 agent 上报的设备名+token 动态注册/复用设备。
// 设备同名换 token 时清理旧映射, 避免 tokenToDevice 残留指向同名设备。
func (s *Store) registerDevToken(name, token string) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if d, ok := s.devices[name]; ok {
		if d.Token != token {
			delete(s.tokenToDevice, d.Token)
		}
		d.Token = token
		s.devices[name] = d
	} else {
		s.devices[name] = Device{Name: name, Token: token, FirstSeen: time.Now().Unix()}
	}
	s.tokenToDevice[token] = name
	s.removePendingByNameLocked(name)
	s.saveDevicesUnlocked()
	s.saveUnregisteredUnlocked()
	return s.devices[name], nil
}

// ---------- 未注册设备检测 ----------

func (s *Store) recordUnregistered(name, ip string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if name == "" {
		name = "(unknown)"
	}
	key := ip + "|" + name
	now := time.Now().Unix()
	if p, ok := s.pending[key]; ok {
		p.LastSeen = now
		p.Count++
	} else {
		s.pending[key] = &PendingDevice{Name: name, IP: ip, FirstSeen: now, LastSeen: now, Count: 1}
	}
	// 防膨胀: 只保留最近 24h 有活动的记录, 最多 100 条
	if len(s.pending) > 100 {
		for k, p := range s.pending {
			if now-p.LastSeen > 24*3600 {
				delete(s.pending, k)
			}
		}
	}
	s.saveUnregisteredUnlocked()
}

func (s *Store) allUnregistered() []*PendingDevice {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := []*PendingDevice{}
	for _, p := range s.pending {
		list = append(list, p)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].LastSeen > list[j].LastSeen })
	return list
}

func (s *Store) clearUnregistered() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pending = map[string]*PendingDevice{}
	s.saveUnregisteredUnlocked()
}

// ---------- 逐设备注册码 ----------

// 为指定设备名生成注册码 (有效期 30 分钟)。已注册设备拒绝; 同名未过期码复用。
func (s *Store) issuePendingCode(name string) (PendingCode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.devices[name]; exists {
		return PendingCode{}, fmt.Errorf("设备 %q 已注册", name)
	}
	now := time.Now().Unix()
	for _, pc := range s.codes {
		if pc.Device == name && pc.ExpiresAt > now {
			return pc, nil
		}
	}
	code, err := pendingCode()
	if err != nil {
		return PendingCode{}, err
	}
	pc := PendingCode{Code: code, Device: name, ExpiresAt: now + 30*60}
	s.codes[code] = pc
	s.saveCodesUnlocked()
	return pc, nil
}

// 校验注册码: 未过期、绑定设备名与上报一致 (上报为空则取绑定名)。过期惰性清理。
func (s *Store) matchPendingCode(token, deviceID string) (PendingCode, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	code, ok := s.codes[token]
	if !ok {
		return PendingCode{}, false
	}
	if code.ExpiresAt < time.Now().Unix() {
		delete(s.codes, token)
		s.saveCodesUnlocked()
		return PendingCode{}, false
	}
	if deviceID != "" && deviceID != code.Device {
		return PendingCode{}, false
	}
	return code, true
}

// 注册码激活: 以绑定设备名注册, 注册码即正式 token, 从 codes 表移除
func (s *Store) activatePendingCode(code PendingCode) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.codes, code.Code)
	s.devices[code.Device] = Device{Name: code.Device, Token: code.Code, FirstSeen: time.Now().Unix()}
	s.tokenToDevice[code.Code] = code.Device
	s.removePendingByNameLocked(code.Device)
	s.saveDevicesUnlocked()
	s.saveCodesUnlocked()
	s.saveUnregisteredUnlocked()
	return s.devices[code.Device], nil
}

func (s *Store) revokePendingCode(code string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.codes, code)
	s.saveCodesUnlocked()
}

func (s *Store) saveUnregisteredUnlocked() {
	var list []*PendingDevice
	for _, p := range s.pending {
		list = append(list, p)
	}
	if data, err := json.MarshalIndent(list, "", "  "); err == nil {
		_ = ioutil.WriteFile(filepath.Join(s.dir, "unregistered.json"), data, 0o644)
	}
}

func (s *Store) saveCodesUnlocked() {
	var list []PendingCode
	for _, c := range s.codes {
		list = append(list, c)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Device < list[j].Device })
	if data, err := json.MarshalIndent(list, "", "  "); err == nil {
		_ = ioutil.WriteFile(filepath.Join(s.dir, "codes.json"), data, 0o644)
	}
}

// ---------- 设备管理 ----------

func (s *Store) deleteDevice(name string, purge bool) {
	s.mu.Lock()
	token := s.devices[name].Token
	delete(s.devices, name)
	if token != "" {
		delete(s.tokenToDevice, token)
	}
	s.saveDevicesUnlocked()
	s.mu.Unlock()
	if purge {
		_ = os.RemoveAll(filepath.Join(s.dir, "history", safeID(name)))
		_ = os.Remove(filepath.Join(s.dir, "latest", safeID(name)+".json"))
	}
}

func (s *Store) renameDevice(name, newName string) error {
	s.mu.Lock()
	d, ok := s.devices[name]
	if !ok {
		s.mu.Unlock()
		return fmt.Errorf("设备 %q 不存在", name)
	}
	if _, exists := s.devices[newName]; exists {
		s.mu.Unlock()
		return fmt.Errorf("设备 %q 已存在", newName)
	}
	delete(s.devices, name)
	d.Name = newName
	s.devices[newName] = d
	s.tokenToDevice[d.Token] = newName
	s.saveDevicesUnlocked()
	s.mu.Unlock()
	// 移动数据目录 (历史 + 最新快照)
	os.Rename(filepath.Join(s.dir, "history", safeID(name)), filepath.Join(s.dir, "history", safeID(newName)))
	os.Rename(filepath.Join(s.dir, "latest", safeID(name)+".json"), filepath.Join(s.dir, "latest", safeID(newName)+".json"))
	return nil
}

func (s *Store) rotateToken(name string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[name]
	if !ok {
		return "", fmt.Errorf("设备 %q 不存在", name)
	}
	old := d.Token
	delete(s.tokenToDevice, old)
	token, err := randomToken()
	if err != nil {
		return "", err
	}
	d.Token = token
	s.devices[name] = d
	s.tokenToDevice[token] = name
	s.saveDevicesUnlocked()
	return token, nil
}

func (s *Store) setSuspended(name string, v bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[name]
	if !ok {
		return fmt.Errorf("设备 %q 不存在", name)
	}
	d.Suspended = v
	s.devices[name] = d
	s.saveDevicesUnlocked()
	return nil
}

// crypto/rand 生成 24 位十六进制 token
func randomToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// crypto/rand 生成 12 位十六进制注册码
func pendingCode() (string, error) {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// ---------- 指标写入 ----------

type MetricPayload struct {
	DeviceID string          `json:"device_id"`
	TS       int64           `json:"ts"`
	Data     json.RawMessage `json:"data"`
}

func (s *Store) ingest(payload MetricPayload, device Device) error {
	ts := payload.TS
	if ts <= 0 {
		ts = time.Now().Unix()
	}
	id := safeID(payload.DeviceID)

	// 1. 追加到当日历史文件
	day := time.Unix(ts, 0).Format("2006-01-02")
	histDir := filepath.Join(s.dir, "history", id)
	if err := os.MkdirAll(histDir, 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(histDir, day+".jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	line := fmt.Sprintf("{\"ts\":%d,\"data\":%s}\n", ts, string(payload.Data))
	_, werr := f.WriteString(line)
	cerr := f.Close()
	if werr != nil {
		return werr
	}
	if cerr != nil {
		return cerr
	}

	// 2. 更新 latest
	latestPath := filepath.Join(s.dir, "latest", id+".json")
	latest := fmt.Sprintf("{\"ts\":%d,\"device_id\":%q,\"data\":%s}\n", ts, payload.DeviceID, string(payload.Data))
	_ = ioutil.WriteFile(latestPath, []byte(latest), 0o644)

	return nil
}

func (s *Store) getLatest(deviceID string) ([]byte, bool) {
	data, err := ioutil.ReadFile(filepath.Join(s.dir, "latest", safeID(deviceID)+".json"))
	if err != nil {
		return nil, false
	}
	return data, true
}

// ---------- 历史查询 ----------

// 点路径取值, 如 "cpu.usage" / "gpu.0.utilization" / "temps.TC0P"
func valueAtPath(data json.RawMessage, path string) (any, bool) {
	parts := strings.Split(path, ".")
	var cur any
	if err := json.Unmarshal(data, &cur); err != nil {
		return nil, false
	}
	for _, p := range parts {
		switch v := cur.(type) {
		case map[string]any:
			vv, exists := v[p]
			if !exists {
				return nil, false
			}
			cur = vv
		case []any:
			idx, err := strconv.Atoi(p)
			if err != nil || idx < 0 || idx >= len(v) {
				return nil, false
			}
			cur = v[idx]
		default:
			return nil, false
		}
	}
	return cur, true
}

type HistoryResponse struct {
	Device string `json:"device"`
	Paths  []string `json:"paths"`
	Series []HistoryPoint `json:"series"`
}

type HistoryPoint struct {
	TS     int64            `json:"ts"`
	Values map[string]any   `json:"values"`
}

func (s *Store) history(deviceID, pathsStr string, hours int, maxPoints int) HistoryResponse {
	resp := HistoryResponse{Device: deviceID, Paths: strings.Split(pathsStr, ","), Series: []HistoryPoint{}}
	if len(resp.Paths) == 0 || resp.Paths[0] == "" {
		return resp
	}
	// 过滤空路径
	var paths []string
	for _, p := range resp.Paths {
		if p = strings.TrimSpace(p); p != "" {
			paths = append(paths, p)
		}
	}
	resp.Paths = paths
	if len(paths) == 0 {
		return resp
	}

	id := safeID(deviceID)
	histDir := filepath.Join(s.dir, "history", id)
	cutoff := time.Now().Add(-time.Duration(hours) * time.Hour)

	// 收集需要读取的日期文件
	var files []string
	entries, _ := ioutil.ReadDir(histDir)
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		day, err := time.Parse("2006-01-02", strings.TrimSuffix(e.Name(), ".jsonl"))
		if err != nil {
			continue
		}
		if day.Before(time.Now().Add(-time.Duration(hours+24) * time.Hour)) {
			continue
		}
		files = append(files, filepath.Join(histDir, e.Name()))
	}
	sort.Strings(files)

	var all []HistoryPoint
	for _, f := range files {
		raw, err := ioutil.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			var rec struct {
				TS   int64           `json:"ts"`
				Data json.RawMessage `json:"data"`
			}
			if json.Unmarshal([]byte(line), &rec) != nil {
				continue
			}
			if rec.TS < cutoff.Unix() {
				continue
			}
			values := map[string]any{}
			for _, p := range paths {
				if v, ok := valueAtPath(rec.Data, p); ok {
					values[p] = v
				}
			}
			if len(values) > 0 {
				all = append(all, HistoryPoint{TS: rec.TS, Values: values})
			}
		}
	}

	// 抽稀到 maxPoints, 保证图表点数可控
	if len(all) > maxPoints {
		step := float64(len(all)) / float64(maxPoints)
		var sampled []HistoryPoint
		for i := 0; i < maxPoints; i++ {
			sampled = append(sampled, all[int(float64(i)*step)])
		}
		all = sampled
	}
	resp.Series = all
	return resp
}

// 删除超过 retentionDays 的历史文件, 返回删除的文件数
func (s *Store) cleanupOldFiles() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := time.Now().Add(-time.Duration(s.retentionDays) * time.Hour * 24)
	histRoot := filepath.Join(s.dir, "history")
	deleted := 0
	devs, _ := ioutil.ReadDir(histRoot)
	for _, dev := range devs {
		if !dev.IsDir() {
			continue
		}
		files, _ := ioutil.ReadDir(filepath.Join(histRoot, dev.Name()))
		for _, f := range files {
			day, err := time.Parse("2006-01-02", strings.TrimSuffix(f.Name(), ".jsonl"))
			if err != nil {
				continue
			}
			if day.Before(cutoff) {
				_ = os.Remove(filepath.Join(histRoot, dev.Name(), f.Name()))
				deleted++
			}
		}
	}
	return deleted
}

// 后台定时清理: 保证窗口外的历史数据持续销毁, 不依赖重启或手动设置
func (s *Store) runCleanupLoop() {
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		s.cleanupOldFiles()
	}
}

// ---------- 留存天数设置 (settings.json 持久化) ----------

func (s *Store) loadSettings() (int, bool) {
	data, err := ioutil.ReadFile(filepath.Join(s.dir, "settings.json"))
	if err != nil {
		return 0, false
	}
	var st struct {
		RetentionDays int `json:"retention_days"`
	}
	if json.Unmarshal(data, &st) != nil || st.RetentionDays < 1 || st.RetentionDays > 365 {
		return 0, false
	}
	return st.RetentionDays, true
}

func (s *Store) saveSettings() {
	data, _ := json.Marshal(map[string]int{"retention_days": s.retentionDays})
	_ = ioutil.WriteFile(filepath.Join(s.dir, "settings.json"), data, 0o644)
}

func (s *Store) retentionDaysValue() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.retentionDays
}

// 设置留存天数并立即清理窗口外数据, 返回删除的历史文件数
func (s *Store) setRetentionDays(n int) int {
	s.mu.Lock()
	s.retentionDays = n
	s.saveSettings()
	s.mu.Unlock()
	return s.cleanupOldFiles()
}

// ---------- 鉴权 ----------

var webPassword string

func checkWebAuth(r *http.Request) bool {
	if webPassword == "" {
		return true // 开发模式不鉴权
	}
	_, pass, ok := r.BasicAuth()
	if !ok {
		// 也接受 X-Auth-Token 头 (前端 localStorage)
		pass = r.Header.Get("X-Auth-Token")
	}
	return subtle.ConstantTimeCompare([]byte(pass), []byte(webPassword)) == 1
}

func requireWebAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !checkWebAuth(r) {
			w.Header().Set("WWW-Authenticate", `Basic realm="macmon"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// 有效 agent token 即可访问 (只读监控接口, 供 App 查看被监控机器)
func (s *Store) requireAgentAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if _, ok := s.deviceByToken(token); !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// ---------- main ----------

func main() {
	port := envOr("PORT", "8080")
	dataDir := envOr("DATA_DIR", "./data")
	webPassword = os.Getenv("WEB_PASSWORD")
	provision := os.Getenv("MACMON_DEVICES")
	retention, _ := strconv.Atoi(envOr("RETENTION_DAYS", ""))

	store, err := NewStore(dataDir, retention)
	if err != nil {
		log.Fatalf("存储初始化失败: %v", err)
	}
	// 运行期持续清理窗口外的历史数据 (默认 1 天, 可在管理页面修改)
	go store.runCleanupLoop()
	if provision != "" {
		names := store.provisionDevices(provision)
		store.saveDevices()
		log.Printf("已预配设备: %v", names)
	} else {
		log.Printf("⚠️  未设置 MACMON_DEVICES, 接受任意 token (仅限开发)")
	}
	if webPassword == "" {
		log.Printf("⚠️  未设置 WEB_PASSWORD, 看板无需登录 (生产环境请设置)")
	}

	mux := http.NewServeMux()

	// 新设备注册: 用共享注册码换专属 token
	setupKey := os.Getenv("SETUP_KEY")
	if setupKey != "" {
		mux.HandleFunc("POST /api/register", func(w http.ResponseWriter, r *http.Request) {
			var req struct {
				SetupKey string `json:"setup_key"`
				Name     string `json:"name"`
			}
			defer r.Body.Close()
			if json.NewDecoder(r.Body).Decode(&req) != nil || req.SetupKey == "" || req.Name == "" {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			if subtle.ConstantTimeCompare([]byte(req.SetupKey), []byte(setupKey)) != 1 {
				http.Error(w, "invalid setup key", http.StatusForbidden)
				return
			}
			token, err := store.registerDevice(req.Name)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			writeJSON(w, map[string]string{"token": token})
		})
	} else {
		log.Printf("⚠️  未设置 SETUP_KEY, 新设备注册接口不可用")
	}

	// Agent 推送
	mux.HandleFunc("POST /api/metrics", func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		device, ok := store.deviceByToken(token)

		defer r.Body.Close()
		body, _ := ioutil.ReadAll(r.Body)
		var payload MetricPayload
		if err := json.Unmarshal(body, &payload); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		// 设备上报的本机 IP 优先于连接来源: NAS 上 Tailscale 用户空间转发会让连接源变成 127.0.0.1
		reportedIP := reportedLocalIP(payload.Data)

		if !ok {
			if provision != "" {
				// 生产模式: 先检查是否为有效的待注册码, 否则记录来源并拒绝
				if code, cok := store.matchPendingCode(token, payload.DeviceID); cok {
					device, _ = store.activatePendingCode(code)
				} else {
					store.recordUnregistered(payload.DeviceID, preferIP(reportedIP, clientIP(r)))
					http.Error(w, "invalid token", http.StatusUnauthorized)
					return
				}
			} else {
				// 开发模式: 接受任意 token, 按 agent 上报的设备名动态注册
				if payload.DeviceID == "" {
					http.Error(w, "device_id required", http.StatusBadRequest)
					return
				}
				var err error
				device, err = store.registerDevToken(payload.DeviceID, token)
				if err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
			}
		}
		if device.Suspended {
			http.Error(w, "device suspended", http.StatusForbidden)
			return
		}
		// 以 token 对应的注册名为准。不随上报的 device_id 自动改名:
		// App 端 device_id 可能是首次运行生成的 UUID, 自动改名会制造并存的僵尸条目
		payload.DeviceID = device.Name
		if err := store.ingest(payload, device); err != nil {
			http.Error(w, "ingest failed", http.StatusInternalServerError)
			return
		}
		store.touchDevice(device, preferIP(reportedIP, clientIP(r)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// 设备管理 API (均需看板鉴权)
	mux.HandleFunc("GET /api/unregistered", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, store.allUnregistered())
	}))

	mux.HandleFunc("POST /api/pending-code", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Device string `json:"device"`
		}
		defer r.Body.Close()
		if json.NewDecoder(r.Body).Decode(&req) != nil || req.Device == "" {
			http.Error(w, "device required", http.StatusBadRequest)
			return
		}
		pc, err := store.issuePendingCode(req.Device)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, pc)
	}))

	mux.HandleFunc("DELETE /api/pending-code", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		code := r.URL.Query().Get("code")
		if code == "" {
			http.Error(w, "code required", http.StatusBadRequest)
			return
		}
		store.revokePendingCode(code)
		w.WriteHeader(http.StatusOK)
	}))

	mux.HandleFunc("POST /api/clear-unregistered", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		store.clearUnregistered()
		w.WriteHeader(http.StatusOK)
	}))

	mux.HandleFunc("GET /api/setup-key", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"setup_key": setupKey})
	}))

	mux.HandleFunc("POST /api/device/delete", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Name  string `json:"name"`
			Purge bool   `json:"purge"`
		}
		defer r.Body.Close()
		if json.NewDecoder(r.Body).Decode(&req) != nil || req.Name == "" {
			http.Error(w, "name required", http.StatusBadRequest)
			return
		}
		store.deleteDevice(req.Name, req.Purge)
		w.WriteHeader(http.StatusOK)
	}))

	mux.HandleFunc("POST /api/device/rename", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Name    string `json:"name"`
			NewName string `json:"new_name"`
		}
		defer r.Body.Close()
		if json.NewDecoder(r.Body).Decode(&req) != nil || req.Name == "" || req.NewName == "" {
			http.Error(w, "name required", http.StatusBadRequest)
			return
		}
		if err := store.renameDevice(req.Name, req.NewName); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))

	mux.HandleFunc("POST /api/device/rotate-token", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Name string `json:"name"`
		}
		defer r.Body.Close()
		if json.NewDecoder(r.Body).Decode(&req) != nil || req.Name == "" {
			http.Error(w, "name required", http.StatusBadRequest)
			return
		}
		token, err := store.rotateToken(req.Name)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, map[string]string{"token": token})
	}))

	mux.HandleFunc("POST /api/device/suspend", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Name      string `json:"name"`
			Suspended bool   `json:"suspended"`
		}
		defer r.Body.Close()
		if json.NewDecoder(r.Body).Decode(&req) != nil || req.Name == "" {
			http.Error(w, "name required", http.StatusBadRequest)
			return
		}
		if err := store.setSuspended(req.Name, req.Suspended); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))

	// 只读监控接口 (agent token 鉴权, 供 App 菜单栏查看被监控机器)
	mux.HandleFunc("GET /api/monitor/devices", store.requireAgentAuth(func(w http.ResponseWriter, r *http.Request) {
		devs := store.allDevices()
		list := make([]map[string]any, 0, len(devs))
		for _, d := range devs {
			list = append(list, map[string]any{
				"name":      d.Name,
				"ip":        d.IP,
				"last_seen": d.LastSeen,
				"suspended": d.Suspended,
			})
		}
		writeJSON(w, list)
	}))

	mux.HandleFunc("POST /api/monitor/snapshots", store.requireAgentAuth(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Devices []string `json:"devices"`
		}
		defer r.Body.Close()
		if json.NewDecoder(r.Body).Decode(&req) != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		out := map[string]any{}
		for _, name := range req.Devices {
			d, ok := store.deviceByName(name)
			if !ok {
				continue
			}
			entry := map[string]any{
				"last_seen": d.LastSeen,
				"suspended": d.Suspended,
			}
			if data, ok := store.getLatest(name); ok {
				entry["latest"] = json.RawMessage(data)
			} else {
				entry["latest"] = nil
			}
			out[name] = entry
		}
		writeJSON(w, out)
	}))

	// 历史数据留存天数 (管理页面可改)
	mux.HandleFunc("GET /api/admin/retention", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"retention_days": store.retentionDaysValue()})
	}))
	mux.HandleFunc("POST /api/admin/retention", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			RetentionDays int `json:"retention_days"`
		}
		defer r.Body.Close()
		if json.NewDecoder(r.Body).Decode(&req) != nil || req.RetentionDays < 1 || req.RetentionDays > 365 {
			http.Error(w, "retention_days must be 1-365", http.StatusBadRequest)
			return
		}
		deleted := store.setRetentionDays(req.RetentionDays)
		writeJSON(w, map[string]any{"retention_days": req.RetentionDays, "deleted": deleted})
	}))

	// 看板 API
	mux.HandleFunc("GET /api/devices", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, store.allDevices())
	}))

	mux.HandleFunc("GET /api/latest", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		device := r.URL.Query().Get("device")
		if device == "" {
			http.Error(w, "missing device", http.StatusBadRequest)
			return
		}
		if data, ok := store.getLatest(device); ok {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(data)
		} else {
			http.Error(w, "no data", http.StatusNotFound)
		}
	}))

	mux.HandleFunc("GET /api/history", requireWebAuth(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		device := q.Get("device")
		paths := q.Get("paths")
		hours, _ := strconv.Atoi(q.Get("hours"))
		if hours <= 0 || hours > 24*30 {
			hours = 24
		}
		if device == "" {
			http.Error(w, "missing device", http.StatusBadRequest)
			return
		}
		writeJSON(w, store.history(device, paths, hours, 3000))
	}))

	// 看板静态文件
	staticFS, _ := fs.Sub(webFS, "web")
	fileServer := http.FileServer(http.FS(staticFS))
	mux.Handle("GET /", fileServer)

	log.Printf("macmon-server 启动: http://0.0.0.0:%s  数据目录=%s", port, dataDir)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// 优先使用设备上报的本机 IP; 连接来源为回环(127.x)时忽略, 退回连接来源
func preferIP(reported, conn string) string {
	reported = strings.TrimSpace(reported)
	if reported == "" || reported == "127.0.0.1" || reported == "::1" || strings.HasPrefix(reported, "127.") {
		return conn
	}
	return reported
}

// 从推送 data 中解析 device.localIP (设备上报的本机 IP)
func reportedLocalIP(data json.RawMessage) string {
	var d struct {
		Device *struct {
			LocalIP string `json:"localIP"`
		} `json:"device"`
	}
	if json.Unmarshal(data, &d) == nil && d.Device != nil {
		return d.Device.LocalIP
	}
	return ""
}
