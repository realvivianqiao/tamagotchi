import AppKit
import Foundation

/// Time-of-day + optional weather for pad greetings.
enum Daypart: String {
  case morning, afternoon, evening, night

  static var current: Daypart {
    switch Calendar.current.component(.hour, from: Date()) {
    case 5..<12: return .morning
    case 12..<17: return .afternoon
    case 17..<21: return .evening
    default: return .night
    }
  }

  var label: String {
    switch self {
    case .morning: return "morning"
    case .afternoon: return "afternoon"
    case .evening: return "evening"
    case .night: return "night"
    }
  }
}

@MainActor final class Ambient {
  static let shared = Ambient()

  /// Short weather blurb, e.g. "72° partly cloudy". Nil if unknown / offline.
  private(set) var weatherBlurb: String?
  private var lastWeatherFetch: Date?
  private var lastGreetedPart: String? // "yyyy-MM-dd-morning"
  private var greetInFlight = false

  private init() {
    lastGreetedPart = UserDefaults.standard.string(forKey: "mochiLastGreetPart")
  }

  /// Call on launch, Mac wake, and after nap.
  /// - `force`: speak even if we already greeted this daypart (use on launch / Mac wake).
  func maybeGreet(
    species: Species,
    asleep: Bool,
    force: Bool = false,
    say: @escaping (String, Double) -> Void
  ) {
    guard !asleep else { return }
    let part = Daypart.current
    let key = Self.partKey(part)
    if !force, lastGreetedPart == key { return }
    lastGreetedPart = key
    UserDefaults.standard.set(key, forKey: "mochiLastGreetPart")

    // Speak immediately — don't wait on weather (wttr can be slow / fail).
    let first = Self.composeGreeting(species: species, part: part, weather: weatherBlurb)
    say(first, part == .morning ? 4.0 : 3.5)

    Task { @MainActor in
      await refreshWeatherIfNeeded()
      let richer = Self.composeGreeting(species: species, part: part, weather: weatherBlurb)
      if richer != first { say(richer, 3.8) }
    }
  }

  /// Wake-from-nap line (always speaks; includes weather if we have it).
  func wakeLine(species: Species) -> String {
    Self.composeGreeting(species: species, part: Daypart.current, weather: weatherBlurb)
  }

  func refreshWeatherIfNeeded() async {
    if let last = lastWeatherFetch, Date().timeIntervalSince(last) < 45 * 60, weatherBlurb != nil {
      return
    }
    if greetInFlight { return }
    greetInFlight = true
    defer { greetInFlight = false }
    do {
      // wttr.in uses IP geolocation — no API key, no Core Location prompt.
      var req = URLRequest(url: URL(string: "https://wttr.in/?format=j1")!)
      req.setValue("CoPet/0.4 (desktop pet; github.com/realvivianqiao/tamagotchi)", forHTTPHeaderField: "User-Agent")
      req.timeoutInterval = 12
      let (data, resp) = try await URLSession.shared.data(for: req)
      guard (resp as? HTTPURLResponse)?.statusCode ?? 500 < 400 else { return }
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let current = (json["current_condition"] as? [[String: Any]])?.first
      else { return }

      let tempF = (current["temp_F"] as? String).flatMap(Int.init)
      let tempC = (current["temp_C"] as? String).flatMap(Int.init)
      let desc = ((current["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""

      let usesF = Locale.current.measurementSystem == .us
      let temp: String? =
        if usesF, let t = tempF { "\(t)°" }
        else if let t = tempC { "\(t)°" }
        else if let t = tempF { "\(t)°F" }
        else { nil }

      let short = Self.shortWeather(desc)
      if let temp, !short.isEmpty {
        weatherBlurb = "\(temp) \(short)"
      } else if let temp {
        weatherBlurb = temp
      } else if !short.isEmpty {
        weatherBlurb = short
      }
      lastWeatherFetch = Date()
    } catch {
      // Weather is optional — greetings still work offline.
    }
  }

  private static func partKey(_ part: Daypart) -> String {
    let f = DateFormatter()
    f.calendar = Calendar.current
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return "\(f.string(from: Date()))-\(part.rawValue)"
  }

  private static func composeGreeting(species: Species, part: Daypart, weather: String?) -> String {
    var line = PetLines.greeting(species, part)
    if let weather, !weather.isEmpty {
      // Keep bubble readable.
      let clipped = weather.count > 28 ? String(weather.prefix(27)) + "…" : weather
      line += " · \(clipped)"
    }
    return line
  }

  private static func shortWeather(_ desc: String) -> String {
    let d = desc.lowercased()
    if d.contains("thunder") { return "stormy" }
    if d.contains("snow") || d.contains("blizzard") { return "snowy" }
    if d.contains("sleet") || d.contains("ice") { return "icy" }
    if d.contains("rain") || d.contains("drizzle") || d.contains("shower") { return "rainy" }
    if d.contains("fog") || d.contains("mist") || d.contains("haze") { return "foggy" }
    if d.contains("overcast") || d.contains("cloud") { return "cloudy" }
    if d.contains("clear") || d.contains("sunny") { return "sunny" }
    if d.contains("partly") { return "partly cloudy" }
    if d.isEmpty { return "" }
    // Fallback: first two words.
    return d.split(separator: " ").prefix(2).joined(separator: " ")
  }
}
