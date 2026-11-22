import SwiftUI

extension WeightUnit {
    /// Display a kg value in this unit, trimmed ("62.5 kg", "137.8 lbs").
    func format(_ kg: Double?, withUnit: Bool = true) -> String {
        guard let kg else { return "—" }
        let s = Self.number(fromKg(kg))
        return withUnit ? "\(s) \(rawValue)" : s
    }

    static func number(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    /// Parse user input in this unit to kg.
    func parseToKg(_ text: String) -> Double? {
        let t = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v >= 0 else { return nil }
        return toKg(v)
    }

    func volume(_ kgReps: Double) -> String {
        let v = fromKg(kgReps)
        if v >= 10_000 { return String(format: "%.1fk", v / 1000) }
        return String(format: "%.0f", v)
    }
}

extension HintTone {
    var color: Color {
        switch self {
        case .success: .green
        case .danger: .red
        case .caution: .orange
        case .muted: .secondary
        }
    }
}

extension SetPerformance {
    var glyph: String { self == .up ? "▲" : self == .met ? "=" : "▼" }
    var color: Color { self == .up ? .green : self == .met ? .secondary : .red }
}

extension Tempo {
    var label: String { self == .fast ? "Fast" : self == .slow ? "Slow" : "Steady" }
    var symbol: String { self == .fast ? "hare" : self == .slow ? "tortoise" : "metronome" }
}

extension LiftVerdict {
    var label: String {
        switch self { case .up: "Up"; case .held: "Held"; case .down: "Down"; case .eased: "Eased"; case .new: "New" }
    }
    var color: Color {
        switch self { case .up: .green; case .held: .secondary; case .down: .red; case .eased: .orange; case .new: .blue }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Small rounded label used throughout.
struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Something went wrong", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message.wrappedValue ?? "") }
    }
}

extension Result {
    var errorMessage: String? {
        if case .failure(let e) = self { return e.localizedDescription }
        return nil
    }
}
