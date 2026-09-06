//
//  ChartView.swift
//  菜单栏弹窗的小型图表 (Swift Charts): 渐变面积 + 描线
//

import SwiftUI
import Charts

/// 单序列面积图 (CPU / 内存 / 温度 / 电池 / GPU)
struct MetricChart: View {
    let points: [(ts: Int64, value: Double)]
    var color: Color = .accentColor

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                AreaMark(
                    x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))),
                    y: .value("v", p.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(colors: [color.opacity(0.35), color.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom)
                )
                LineMark(
                    x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))),
                    y: .value("v", p.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 46)
    }
}

/// 双序列折线图 (网络 下行/上行)
struct NetworkChart: View {
    let points: [(ts: Int64, rx: Double, tx: Double)]   // 字节/秒

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))),
                         y: .value("rx", p.rx), series: .value("dir", "rx"))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))),
                         y: .value("tx", p.tx), series: .value("dir", "tx"))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 46)
    }
}
