import CoreAudio
import Foundation
import IOKit.ps
import RookKit
@preconcurrency import UserNotifications

struct RookReflexExecution {
    let displayText: String
    let spokenText: String
    let canvas: RookCanvasBlock
}

enum RookLocalAlertStatus: String, Codable {
    case scheduled
    case fired
    case cancelled
}

struct RookLocalAlert: Codable, Identifiable {
    let id: UUID
    let kind: RookLocalAlertKind
    let message: String
    let createdAt: Date
    let dueAt: Date
    var status: RookLocalAlertStatus
}

enum RookReflexError: LocalizedError {
    case divisionByZero
    case unsupportedConversion
    case batteryUnavailable
    case storageUnavailable
    case audioUnavailable(String)
    case noAlert(RookLocalAlertKind?)
    case ambiguousAlerts(Int, RookLocalAlertKind?)

    var errorDescription: String? {
        switch self {
        case .divisionByZero:
            "That calculation would divide by zero."
        case .unsupportedConversion:
            "That conversion is not available in the local reflex layer yet."
        case .batteryUnavailable:
            "This Mac did not report a battery."
        case .storageUnavailable:
            "macOS did not report the available storage."
        case .audioUnavailable(let detail):
            "The current audio output does not expose that control: \(detail)"
        case .noAlert(let kind):
            "There is no active \(kind?.rawValue ?? "local alert") to cancel."
        case .ambiguousAlerts(let count, let kind):
            "There are \(count) active \(kind.map { $0.rawValue + "s" } ?? "alerts"). Say which one you want to cancel."
        }
    }
}

@MainActor
final class RookReflexController {
    typealias Completion = (Result<RookReflexExecution, Error>) -> Void

    var onAlert: ((RookLocalAlert) -> Void)?

    private let config: RookConfig
    private let notificationCenter = UNUserNotificationCenter.current()
    private var alerts: [RookLocalAlert] = []
    private var timers: [UUID: Timer] = [:]

    init(config: RookConfig) {
        self.config = config
        loadAlerts()
    }

    func start() {
        let now = Date()
        var changed = false
        for index in alerts.indices where alerts[index].status == .scheduled {
            if alerts[index].dueAt <= now {
                alerts[index].status = .fired
                changed = true
            } else {
                scheduleInAppTimer(for: alerts[index])
                scheduleSystemNotification(for: alerts[index])
            }
        }
        if changed { persistAlerts() }
    }

    func execute(_ intent: RookReflexIntent, completion: Completion) {
        do {
            let execution: RookReflexExecution
            switch intent {
            case .calculation(let calculation):
                execution = try calculate(calculation)
            case .conversion(let conversion):
                execution = try convert(conversion)
            case .scheduleAlert(let kind, let dueAt, let message):
                execution = scheduleAlert(kind: kind, dueAt: dueAt, message: message)
            case .listAlerts(let kind):
                execution = listAlerts(kind: kind)
            case .cancelAlert(let kind):
                execution = try cancelAlert(kind: kind)
            case .deviceStatus(let status):
                execution = try deviceStatus(status)
            case .volume(let action):
                execution = try controlVolume(action)
            }
            completion(.success(execution))
        } catch {
            completion(.failure(error))
        }
    }

    private func calculate(_ calculation: RookCalculation) throws -> RookReflexExecution {
        guard let result = calculation.result else { throw RookReflexError.divisionByZero }
        let answer = RookReflexFormatter.number(result)
        return RookReflexExecution(
            displayText: "**\(answer)**\n\n\(calculation.expression) = \(answer)",
            spokenText: "The answer is \(answer).",
            canvas: RookCanvasBlock(
                id: "quick_calculation",
                kind: .list,
                title: "Quick calculation",
                subtitle: calculation.expression,
                items: [RookCanvasItem(
                    id: "calculation_result",
                    label: "Result",
                    detail: calculation.expression,
                    value: answer,
                    symbol: .info
                )]
            )
        )
    }

    private func convert(_ conversion: RookConversion) throws -> RookReflexExecution {
        guard let result = conversion.result else { throw RookReflexError.unsupportedConversion }
        let answer = "\(RookReflexFormatter.number(result)) \(conversion.to.shortLabel)"
        return RookReflexExecution(
            displayText: "**\(answer)**\n\n\(conversion.expression)",
            spokenText: "That's \(answer).",
            canvas: RookCanvasBlock(
                id: "quick_conversion",
                kind: .list,
                title: "Quick conversion",
                subtitle: conversion.expression,
                items: [RookCanvasItem(
                    id: "conversion_result",
                    label: "Converted value",
                    detail: conversion.expression,
                    value: answer,
                    symbol: .info
                )]
            )
        )
    }

    private func scheduleAlert(kind: RookLocalAlertKind, dueAt: Date, message: String) -> RookReflexExecution {
        let cleanedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = RookLocalAlert(
            id: UUID(),
            kind: kind,
            message: cleanedMessage.isEmpty ? kind.rawValue.capitalized : cleanedMessage,
            createdAt: Date(),
            dueAt: dueAt,
            status: .scheduled
        )
        alerts.append(alert)
        persistAlerts()
        scheduleInAppTimer(for: alert)
        scheduleSystemNotification(for: alert)

        let when = Self.displayDateTime(dueAt)
        let title = kind == .timer ? "Timer set" : "Reminder set"
        let detail = kind == .timer && alert.message == "Timer" ? "Local Rook timer" : alert.message
        return RookReflexExecution(
            displayText: "**\(title) for \(when).**\n\n\(detail)",
            spokenText: "\(title) for \(Self.spokenDateTime(dueAt)).",
            canvas: RookCanvasBlock(
                id: "local_alert",
                kind: .list,
                title: title,
                subtitle: "Private · stored on this Mac",
                items: [RookCanvasItem(
                    id: "alert_due",
                    label: detail,
                    detail: kind.rawValue.capitalized,
                    value: when,
                    symbol: .clock,
                    start: ISO8601DateFormatter().string(from: dueAt)
                )]
            )
        )
    }

    private func listAlerts(kind: RookLocalAlertKind?) -> RookReflexExecution {
        let active = activeAlerts(kind: kind)
        let noun = kind.map { $0.rawValue + "s" } ?? "alerts"
        let display: String
        let spoken: String
        if active.isEmpty {
            display = "**No active \(noun).**"
            spoken = "You don't have any active \(noun)."
        } else {
            let rows = active.map { "- **\($0.message)** — \(Self.displayDateTime($0.dueAt))" }
            display = "**Active \(noun)**\n\n" + rows.joined(separator: "\n")
            spoken = "You have \(active.count) active \(noun)."
        }
        return RookReflexExecution(
            displayText: display,
            spokenText: spoken,
            canvas: RookCanvasBlock(
                id: "active_alerts",
                kind: .list,
                title: "Active \(noun)",
                subtitle: "Stored privately on this Mac",
                items: active.enumerated().map { offset, alert in
                    RookCanvasItem(
                        id: "alert_\(offset + 1)",
                        label: alert.message,
                        detail: alert.kind.rawValue.capitalized,
                        value: Self.displayDateTime(alert.dueAt),
                        symbol: .clock,
                        start: ISO8601DateFormatter().string(from: alert.dueAt)
                    )
                }
            )
        )
    }

    private func cancelAlert(kind: RookLocalAlertKind?) throws -> RookReflexExecution {
        let active = activeAlerts(kind: kind)
        guard !active.isEmpty else { throw RookReflexError.noAlert(kind) }
        guard active.count == 1, let target = active.first else {
            throw RookReflexError.ambiguousAlerts(active.count, kind)
        }
        guard let index = alerts.firstIndex(where: { $0.id == target.id }) else {
            throw RookReflexError.noAlert(kind)
        }
        alerts[index].status = .cancelled
        timers.removeValue(forKey: target.id)?.invalidate()
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [target.id.uuidString])
        persistAlerts()
        return RookReflexExecution(
            displayText: "Cancelled **\(target.message)**, which was due \(Self.displayDateTime(target.dueAt)).",
            spokenText: "Cancelled.",
            canvas: RookCanvasBlock(
                id: "cancelled_alert",
                kind: .list,
                title: "Local alert cancelled",
                items: [RookCanvasItem(
                    id: "cancelled_item",
                    label: target.message,
                    detail: target.kind.rawValue.capitalized,
                    value: "Cancelled",
                    symbol: .clock
                )]
            )
        )
    }

    private func deviceStatus(_ status: RookDeviceStatusKind) throws -> RookReflexExecution {
        switch status {
        case .battery:
            let battery = try batteryStatus()
            return deviceExecution(
                title: "Battery",
                detail: battery.detail,
                value: battery.value,
                spoken: battery.spoken
            )
        case .storage:
            let storage = try storageStatus()
            return deviceExecution(
                title: "Storage available",
                detail: storage.detail,
                value: storage.value,
                spoken: storage.spoken
            )
        case .volume:
            let volume = try outputVolume()
            let percent = Int((volume * 100).rounded())
            return deviceExecution(
                title: "Output volume",
                detail: "Current default audio output",
                value: "\(percent)%",
                spoken: "Your volume is at \(percent) percent."
            )
        }
    }

    private func controlVolume(_ action: RookVolumeAction) throws -> RookReflexExecution {
        let device = try defaultOutputDevice()
        var target: Float32
        var detail: String
        switch action {
        case .set(let value):
            target = Float32(min(1, max(0, value)))
            try setMute(false, device: device, onlyIfSupported: true)
            try setOutputVolume(target, device: device)
            detail = "Volume set"
        case .adjust(let amount):
            target = min(1, max(0, try outputVolume(device: device) + Float32(amount)))
            try setMute(false, device: device, onlyIfSupported: true)
            try setOutputVolume(target, device: device)
            detail = amount >= 0 ? "Volume raised" : "Volume lowered"
        case .mute:
            try setMute(true, device: device, onlyIfSupported: false)
            target = try outputVolume(device: device)
            detail = "Muted"
        case .unmute:
            try setMute(false, device: device, onlyIfSupported: false)
            target = try outputVolume(device: device)
            detail = "Unmuted"
        }
        let value = action == .mute ? "Muted" : "\(Int((target * 100).rounded()))%"
        return deviceExecution(
            title: "Output volume",
            detail: detail,
            value: value,
            spoken: action == .mute ? "Muted." : "Volume is at \(Int((target * 100).rounded())) percent."
        )
    }

    private func deviceExecution(title: String, detail: String, value: String, spoken: String) -> RookReflexExecution {
        RookReflexExecution(
            displayText: "**\(title): \(value)**\n\n\(detail)",
            spokenText: spoken,
            canvas: RookCanvasBlock(
                id: "device_status",
                kind: .computer,
                title: "This Mac",
                subtitle: "Read directly from macOS",
                items: [RookCanvasItem(
                    id: "device_value",
                    label: title,
                    detail: detail,
                    value: value,
                    symbol: .computer
                )]
            )
        )
    }

    private func batteryStatus() throws -> (value: String, detail: String, spoken: String) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let rawSources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            throw RookReflexError.batteryUnavailable
        }
        for source in rawSources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else { continue }
            let percent = Int((current.doubleValue / maximum.doubleValue * 100).rounded())
            let powerState = description[kIOPSPowerSourceStateKey] as? String
            let charging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue == true
            let state = charging ? "Charging" : (powerState == kIOPSACPowerValue ? "On power" : "On battery")
            return ("\(percent)%", state, "Your battery is at \(percent) percent, \(state.lowercased()).")
        }
        throw RookReflexError.batteryUnavailable
    }

    private func storageStatus() throws -> (value: String, detail: String, spoken: String) {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              let total = attributes[.systemSize] as? NSNumber else {
            throw RookReflexError.storageUnavailable
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        let freeText = formatter.string(fromByteCount: free.int64Value)
        let totalText = formatter.string(fromByteCount: total.int64Value)
        return (freeText, "\(freeText) free of \(totalText)", "You have \(freeText) of storage available.")
    }

    private func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard status == noErr, device != 0 else {
            throw RookReflexError.audioUnavailable("no default output device")
        }
        return device
    }

    private func outputVolume() throws -> Float32 {
        try outputVolume(device: defaultOutputDevice())
    }

    private func outputVolume(device: AudioDeviceID) throws -> Float32 {
        for var address in volumeAddresses where AudioObjectHasProperty(device, &address) {
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        throw RookReflexError.audioUnavailable("volume is controlled by the connected device")
    }

    private func setOutputVolume(_ volume: Float32, device: AudioDeviceID) throws {
        var changed = false
        for var address in volumeAddresses where AudioObjectHasProperty(device, &address) {
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var target = volume
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &target) == noErr { changed = true }
        }
        guard changed else {
            throw RookReflexError.audioUnavailable("volume is controlled by the connected device")
        }
    }

    private func setMute(_ muted: Bool, device: AudioDeviceID, onlyIfSupported: Bool) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else {
            if onlyIfSupported { return }
            throw RookReflexError.audioUnavailable("mute is controlled by the connected device")
        }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            if onlyIfSupported { return }
            throw RookReflexError.audioUnavailable("mute is controlled by the connected device")
        }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
        if status != noErr, !onlyIfSupported {
            throw RookReflexError.audioUnavailable("macOS rejected the mute change")
        }
    }

    private var volumeAddresses: [AudioObjectPropertyAddress] {
        [kAudioObjectPropertyElementMain, 1, 2].map { element in
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
        }
    }

    private func activeAlerts(kind: RookLocalAlertKind?) -> [RookLocalAlert] {
        alerts.filter { alert in
            alert.status == .scheduled && alert.dueAt > Date() && (kind == nil || alert.kind == kind)
        }.sorted { $0.dueAt < $1.dueAt }
    }

    private func scheduleInAppTimer(for alert: RookLocalAlert) {
        let delay = alert.dueAt.timeIntervalSinceNow
        guard delay > 0 else { return }
        timers[alert.id]?.invalidate()
        timers[alert.id] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fireAlert(id: alert.id) }
        }
    }

    private func fireAlert(id: UUID) {
        guard let index = alerts.firstIndex(where: { $0.id == id && $0.status == .scheduled }) else { return }
        alerts[index].status = .fired
        timers.removeValue(forKey: id)?.invalidate()
        persistAlerts()
        onAlert?(alerts[index])
    }

    private func scheduleSystemNotification(for alert: RookLocalAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.kind == .timer ? "Rook Timer" : "Rook Reminder"
        content.body = alert.message
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, alert.dueAt.timeIntervalSinceNow),
            repeats: false
        )
        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: trigger)
        let center = notificationCenter
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func loadAlerts() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: config.reflexAlertsURL),
              let decoded = try? decoder.decode([RookLocalAlert].self, from: data) else { return }
        alerts = decoded
    }

    private func persistAlerts() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(alerts) else { return }
        try? RookConfig.writePrivate(data, to: config.reflexAlertsURL)
    }

    private static func displayDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return formatter.string(from: date)
    }

    private static func spokenDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEEE 'at' h:mm a"
        return formatter.string(from: date)
    }
}
