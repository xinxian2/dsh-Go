import BackgroundTasks
import UIKit

/// Keeps a turn the user started going after they leave the app, where the system allows it:
/// iOS 26 and later, while it isn't short of resources. The system shows its own progress card
/// and the user can end the task there. Elsewhere, and once it ends, the engine pauses at its
/// next tool call as it always did. Main thread only.
final class ContinuedRun {
  /// Whether the task is running now.
  var onChange: ((Bool) -> Void)?
  var onDiagnostic: ((String) -> Void)?
  var isPictureInPictureKeepingAlive: (() -> Bool)?

  private var wanted = false
  /// The system or the user ended it: not again until the next turn.
  private var spent = false
  private var submitted: String?
  private var task: BGTask?
  private var progress: Timer?

  init() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  func update(running: Bool) {
    guard running != wanted else { return }
    wanted = running
    if running {
      spent = false
      submit()
    } else {
      finish(success: true)
    }
  }

  /// A turn can start while the app is on its way out, and a request is only accepted in front.
  @objc private func becameActive() {
    if wanted { submit() }
  }

  private func submit() {
    guard #available(iOS 26.0, *), !spent, task == nil, submitted == nil,
      UIApplication.shared.applicationState == .active
    else { return }
    // Each request registers its own identifier, so a late launch can't be taken for a newer turn's.
    let identifier = "\(Bundle.main.bundleIdentifier ?? "dsh").continued.\(UUID().uuidString)"
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
      guard let self, let task = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self.started(task)
    }
    guard registered else {
      onDiagnostic?("registration_failed")
      return
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: String(localized: "DSH Go background execution"),
      subtitle: String(localized: "Keeping the local engine available"))
    // Now or not at all: a turn is no use to anyone once it has already paused.
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
      submitted = identifier
      onDiagnostic?("submitted")
    } catch {
      onDiagnostic?("submission_failed_\((error as NSError).code)")
    }
  }

  @available(iOS 26.0, *)
  private func started(_ task: BGContinuedProcessingTask) {
    guard wanted, task.identifier == submitted else {
      task.setTaskCompleted(success: false)
      return
    }
    submitted = nil
    self.task = task
    task.expirationHandler = { [weak self, weak task] in
      DispatchQueue.main.async {
        guard let self, let task, self.task === task else { return }
        self.spent = true
        // This task grants execution time. The engine can keep running after
        // a handoff even though this particular grant is ending.
        let handedOff = UIApplication.shared.applicationState == .active ||
          self.isPictureInPictureKeepingAlive?() == true
        self.onDiagnostic?(handedOff ? "expired_handed_off" : "expired")
        self.finish(success: handedOff)
      }
    }
    // A turn's length isn't known and the system expects to see progress: this moves and never ends.
    task.progress.totalUnitCount = 1_000_000
    progress = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak task] _ in
      task?.progress.completedUnitCount += 1
    }
    onDiagnostic?("started")
    onChange?(true)
  }

  private func finish(success: Bool) {
    progress?.invalidate()
    progress = nil
    if let submitted {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: submitted)
      self.submitted = nil
    }
    guard let running = task else { return }
    task = nil
    running.setTaskCompleted(success: success)
    onChange?(false)
  }
}
