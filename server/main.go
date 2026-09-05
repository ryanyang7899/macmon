// macmon-server: 远程监控数据接收/存储/看板服务器
//
// 纯标准库, 零第三方依赖。编译成单二进制, 跑在任意 Linux/macOS。
//
// 环境变量:
//   PORT          监听端口          (默认 8080)
//   DATA_DIR      数据目录          (默认 ./data)
//   WEB_PASSWORD  看板登录密码      (默认空=不鉴权, 生产环境必须设置)
//   MACMON_DEVICES 预配设备 "name=token;name2=token2" (默认空=接受任意 token, 开发用)
//   RETENTION_DAYS 历史保留天数     (默认 7)
//
// 接口:
//   POST /api/metrics            Agent 推送 (Bearer token)
//   GET  /api/devices            设备列表 (需要看板密码)
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
	devices       map[string]Device   // deviceID -> 设备信息
	tokenToDevice map[string]string   // token -> deviceID
	retentionDays int
}

type Device struct {
	Name      string `json:"name"`
	Token     string `json:"token"`
	FirstSeen int64  `json:"first_seen"`
	LastSeen  int64  `json:"last_seen"`
	IP        string `json:"ip"`
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
		retentionDays: retentionDays,
	}
	if err := os.MkdirAll(filepath.Join(dir, "history"), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dir, "latest"), 0o755); err != nil {
		return nil, err
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
		if _, ok := s.devices[name]; !ok {
			s.devices[name] = Device{Name: name, Token: token}
		}
		s.tokenToDevice[token] = name
		names = append(names, name)
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
	var list []Device
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
	s.devices[name] = Device{Name: name, Token: token}
	s.tokenToDevice[token] = name
	s.saveDevicesUnlocked()
	return token, nil
}

// crypto/rand 生成 24 位十六进制 token
func randomToken() (string, error) {
	b := make([]byte, 16)
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

// 删除超过 retentionDays 的历史文件
func (s *Store) cleanupOldFiles() {
	cutoff := time.Now().Add(-time.Duration(s.retentionDays) * time.Hour * 24)
	histRoot := filepath.Join(s.dir, "history")
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
			}
		}
	}
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

// ---------- main ----------

func main() {
	port := envOr("PORT", "8080")
	dataDir := envOr("DATA_DIR", "./data")
	webPassword = os.Getenv("WEB_PASSWORD")
	provision := os.Getenv("MACMON_DEVICES")
	retention, _ := strconv.Atoi(envOr("RETENTION_DAYS", "7"))

	store, err := NewStore(dataDir, retention)
	if err != nil {
		log.Fatalf("存储初始化失败: %v", err)
	}
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
		if !ok {
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}
		defer r.Body.Close()
		body, _ := ioutil.ReadAll(r.Body)
		var payload MetricPayload
		if err := json.Unmarshal(body, &payload); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		// 以 token 对应的设备名为准, 避免 Agent 端 deviceID 不一致
		payload.DeviceID = device.Name
		if err := store.ingest(payload, device); err != nil {
			http.Error(w, "ingest failed", http.StatusInternalServerError)
			return
		}
		store.touchDevice(device, clientIP(r))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

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
