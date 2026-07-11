import Foundation

final class ReminderSaveQueue {
    private enum Payload {
        case reminders([Reminder])
        case rawText(String)

        var text: String {
            switch self {
            case .reminders(let reminders):
                return ReminderTextParser.serialize(reminders)
            case .rawText(let text):
                return text
            }
        }
    }

    private struct PendingSave {
        let payload: Payload
        let completion: (URL, Error?) -> Void
        let timer: DispatchSourceTimer
    }

    private let queue = DispatchQueue(label: "Reminder.FileSaveQueue", qos: .utility)
    private var pendingSaves: [URL: PendingSave] = [:]

    func schedule(
        reminders: [Reminder],
        to url: URL,
        delay: TimeInterval = 5,
        completion: @escaping (URL, Error?) -> Void
    ) {
        schedule(payload: .reminders(reminders), to: url, delay: delay, completion: completion)
    }

    func schedule(
        rawText: String,
        to url: URL,
        delay: TimeInterval = 5,
        completion: @escaping (URL, Error?) -> Void
    ) {
        schedule(payload: .rawText(rawText), to: url, delay: delay, completion: completion)
    }

    func flush() -> [URL: Error] {
        queue.sync {
            flushPendingSaves()
        }
    }

    func flush(url: URL) -> Error? {
        queue.sync {
            guard let pendingSave = pendingSaves.removeValue(forKey: url) else {
                return nil
            }

            pendingSave.timer.cancel()
            return write(pendingSave.payload, to: url)
        }
    }

    private func schedule(
        payload: Payload,
        to url: URL,
        delay: TimeInterval,
        completion: @escaping (URL, Error?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            pendingSaves[url]?.timer.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            pendingSaves[url] = PendingSave(
                payload: payload,
                completion: completion,
                timer: timer
            )

            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler { [weak self] in
                self?.writePendingSave(url: url)
            }
            timer.resume()
        }
    }

    private func writePendingSave(url: URL) {
        guard let pendingSave = pendingSaves.removeValue(forKey: url) else {
            return
        }

        pendingSave.timer.cancel()
        let error = write(pendingSave.payload, to: url)
        DispatchQueue.main.async {
            pendingSave.completion(url, error)
        }
    }

    private func flushPendingSaves() -> [URL: Error] {
        let saves = pendingSaves
        pendingSaves.removeAll()
        var errors: [URL: Error] = [:]

        for (url, pendingSave) in saves {
            pendingSave.timer.cancel()
            if let error = write(pendingSave.payload, to: url) {
                errors[url] = error
            }
        }

        return errors
    }

    private func write(_ payload: Payload, to url: URL) -> Error? {
        do {
            try payload.text.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error
        }
    }
}
