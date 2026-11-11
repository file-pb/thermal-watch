import AppKit

/// Graf efektivní rychlosti za okno historie + pás tepelného stavu pod ním.
final class ChartView: NSView {
    var samples: [Sample] = []
    var windowMinutes: Double = 30
    /// Pro export do PNG: v menu je podklad systémový, v obrázku by byl průhledný.
    var opaqueBackground = false

    static let colors: [NSColor] = [
        NSColor.systemGreen, NSColor.systemOrange, NSColor.systemRed
    ]

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let leftGutter: CGFloat = opaqueBackground ? 54 : 44
        let inset = NSRect(x: leftGutter, y: 24,
                           width: bounds.width - leftGutter - 12, height: bounds.height - 34)
        if opaqueBackground {
            NSColor.white.setFill()
        } else {
            NSColor.clear.setFill()
        }
        bounds.fill()

        let yMin = 45.0, yMax = 108.0
        func yFor(_ pct: Double) -> CGFloat {
            let c = max(yMin, min(yMax, pct))
            return inset.minY + inset.height * CGFloat((c - yMin) / (yMax - yMin))
        }

        // vodicí linky 100 / 92 / 80 %
        let font = NSFont.systemFont(ofSize: opaqueBackground ? 12 : 9)
        let labelColor = opaqueBackground ? NSColor.darkGray : NSColor.tertiaryLabelColor
        let gridColor = opaqueBackground
            ? NSColor.lightGray.withAlphaComponent(0.8) : NSColor.separatorColor
        for (pct, label) in [(100.0, "100"), (92.0, "92"), (80.0, "80")] {
            let y = yFor(pct)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: inset.minX, y: y))
            p.line(to: NSPoint(x: inset.maxX, y: y))
            p.setLineDash([2, 3], count: 2, phase: 0)
            gridColor.setStroke()
            p.lineWidth = 1
            p.stroke()
            (label + " %" as NSString).draw(
                at: NSPoint(x: 6, y: y - 6),
                withAttributes: [.font: font, .foregroundColor: labelColor])
        }

        guard samples.compactMap(\.speedPct).count >= 2 else {
            ("sbírám data…" as NSString).draw(
                at: NSPoint(x: inset.midX - 32, y: inset.midY),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                 .foregroundColor: labelColor])
            return
        }

        // x podle času, ne podle indexu – mezery v datech jsou vidět
        let now = Date().timeIntervalSince1970
        let t0 = now - windowMinutes * 60
        func xFor(_ t: Double) -> CGFloat {
            inset.minX + inset.width * CGFloat(max(0, min(1, (t - t0) / (windowMinutes * 60))))
        }

        // Souvislé úseky: mezera delší než maxGap (aplikace neběžela) se nespojuje,
        // jinak by chybějící data vypadala jako pozvolný propad.
        let maxGap: Double = 20
        var runs: [[Sample]] = []
        var run: [Sample] = []
        for s in samples {
            // Neměřený vzorek řadu přeruší – kreslit se dá jen to, co se změřilo.
            guard s.speedPct != nil else {
                if !run.isEmpty { runs.append(run); run = [] }
                continue
            }
            if let last = run.last, s.t - last.t > maxGap { runs.append(run); run = [] }
            run.append(s)
        }
        if !run.isEmpty { runs.append(run) }

        for r in runs where r.count >= 2 {
            // plocha pod křivkou
            let area = NSBezierPath()
            area.move(to: NSPoint(x: xFor(r[0].t), y: inset.minY))
            for s in r { area.line(to: NSPoint(x: xFor(s.t), y: yFor(s.speedPct ?? 100))) }
            area.line(to: NSPoint(x: xFor(r.last!.t), y: inset.minY))
            area.close()
            // Výplň je neutrální schválně: barvu stavu nese křivka, obarvit celou
            // plochu podle posledního vzorku by přemalovalo i historii.
            NSColor.systemGray.withAlphaComponent(0.14).setFill()
            area.fill()

            // křivka po úsecích – barva podle stavu, aby propad nevypadal zeleně
            for i in 1..<r.count {
                let a = r[i - 1], b = r[i]
                let seg = NSBezierPath()
                seg.move(to: NSPoint(x: xFor(a.t), y: yFor(a.speedPct ?? 100)))
                seg.line(to: NSPoint(x: xFor(b.t), y: yFor(b.speedPct ?? 100)))
                seg.lineWidth = 1.5
                ChartView.colors[max(Verdict.overall(a).rawValue,
                                     Verdict.overall(b).rawValue)].setStroke()
                seg.stroke()
            }
        }

        // pás tepelného stavu
        for s in samples {
            guard let lvl = Verdict.pressureTick(s.pressure) else { continue }
            let x = xFor(s.t)
            let r = NSRect(x: x, y: inset.minY - 8, width: 2, height: 5)
            ChartView.colors[lvl.rawValue].withAlphaComponent(0.85).setFill()
            r.fill()
        }

        let small: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: labelColor]
        ("−\(Int(windowMinutes)) min" as NSString).draw(at: NSPoint(x: inset.minX, y: 4), withAttributes: small)
        ("nyní" as NSString).draw(at: NSPoint(x: inset.maxX - 24, y: 4), withAttributes: small)
        ("pás dole = tepelný tlak" as NSString).draw(
            at: NSPoint(x: inset.midX - (opaqueBackground ? 72 : 52), y: 4), withAttributes: small)
    }
}
