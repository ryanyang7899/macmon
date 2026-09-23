//
//  fan.go
//  远程风扇控制的下行命令通道。
//
//  被监控设备在 NAT 后面, App 无法直连它, 因此用"队列 + 拉取"模型:
//
//    App  --POST /api/fan/command-->  服务器 (命令入队, TTL 30s)
//    设备 --GET  /api/fan/commands--> 服务器 (取走并清空自己的队列)
//    设备 --POST /api/fan/result  --> 服务器 (回报执行结果)
//    App  --GET  /api/fan/state   --> 服务器 (读最近一次结果)
//
//  命令是"至多一次": GET 时即出队, 设备没执行成功也不会重复下发,
//  避免网络抖动导致同一条指令被反复写入 SMC。
//

package main

import (
	"sync"
	"time"
)

// 命令存活时间: 超时未取走就作废, 防止设备离线后重连执行一条陈旧指令
const fanCommandTTL = 30 * time.Second

// 每台设备最多积压的命令数 (超出丢弃最旧的)
const fanQueueMax = 8

// FanCommand 一条待执行的风扇指令
type FanCommand struct {
	ID      string `json:"id"`
	FanID   int    `json:"fan_id"`
	Action  string `json:"action"` // speed | auto | reset
	// rpm 始终下发 (不用 omitempty): auto/reset 指令 rpm 为 0, 一旦省略,
	// 客户端按非可选字段解析就会整批失败, 而指令已出队无法重发。
	RPM     int    `json:"rpm"`
	Created int64  `json:"created"`
}

// FanResult 设备回报的执行结果
type FanResult struct {
	CommandID string `json:"command_id"`
	OK        bool   `json:"ok"`
	Error     string `json:"error,omitempty"`
	At        int64  `json:"at"`
}

// fanQueue 命令队列与结果表 (内嵌在 Store 中, 由 Store.mu 保护)
type fanQueue struct {
	mu      sync.Mutex
	pending map[string][]FanCommand // deviceID -> 待执行
	results map[string]FanResult    // deviceID -> 最近一次结果
}

func newFanQueue() *fanQueue {
	return &fanQueue{
		pending: map[string][]FanCommand{},
		results: map[string]FanResult{},
	}
}

// enqueue 把命令加入某台设备的队列, 并清掉已过期的旧命令
func (q *fanQueue) enqueue(deviceID string, cmd FanCommand) {
	q.mu.Lock()
	defer q.mu.Unlock()

	now := time.Now()
	kept := q.pending[deviceID][:0]
	for _, c := range q.pending[deviceID] {
		if now.Sub(time.Unix(c.Created, 0)) < fanCommandTTL {
			kept = append(kept, c)
		}
	}
	kept = append(kept, cmd)
	// 积压过多时丢最旧的
	if len(kept) > fanQueueMax {
		kept = kept[len(kept)-fanQueueMax:]
	}
	q.pending[deviceID] = kept
}

// take 取走并清空某台设备的待执行命令 (至多一次)
func (q *fanQueue) take(deviceID string) []FanCommand {
	q.mu.Lock()
	defer q.mu.Unlock()

	list := q.pending[deviceID]
	q.pending[deviceID] = nil

	now := time.Now()
	out := make([]FanCommand, 0, len(list))
	for _, c := range list {
		if now.Sub(time.Unix(c.Created, 0)) < fanCommandTTL {
			out = append(out, c)
		}
	}
	return out
}

// record 记录执行结果
func (q *fanQueue) record(deviceID string, res FanResult) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.results[deviceID] = res
}

// lastResult 读取最近一次执行结果
func (q *fanQueue) lastResult(deviceID string) (FanResult, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	res, ok := q.results[deviceID]
	return res, ok
}

// reset 设备删除时清理其队列与结果
func (q *fanQueue) reset(deviceID string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	delete(q.pending, deviceID)
	delete(q.results, deviceID)
}
