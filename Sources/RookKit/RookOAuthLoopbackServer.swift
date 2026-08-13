import Foundation
import Network

public final class RookOAuthLoopbackServer: @unchecked Sendable {
  public typealias ReadyHandler = (Result<URL, Error>) -> Void
  public typealias CallbackHandler = (Result<URL, Error>) -> Void

  private let queue = DispatchQueue(label: "com.noah.rook.oauth.loopback")
  private var listener: NWListener?
  private var timeoutWorkItem: DispatchWorkItem?
  private var didFinish = false
  private let requestedPort: NWEndpoint.Port

  public init(port: UInt16? = nil) {
    requestedPort = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
  }

  public func start(onReady: @escaping ReadyHandler, onCallback: @escaping CallbackHandler) {
    do {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requestedPort)
      let listener = try NWListener(using: parameters)
      self.listener = listener

      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = listener.port,
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")
          else {
            self.finish(
              .failure(RookOAuthError.callback("Rook could not create the OAuth callback address.")),
              callback: onCallback
            )
            return
          }
          DispatchQueue.main.async { onReady(.success(url)) }
        case .failed(let error):
          self.finish(
            .failure(RookOAuthError.callback("The local OAuth callback failed: \(error.localizedDescription)")),
            callback: onCallback
          )
        default:
          break
        }
      }

      listener.newConnectionHandler = { [weak self] connection in
        self?.receive(connection: connection, callback: onCallback)
      }
      listener.start(queue: queue)

      let timeout = DispatchWorkItem { [weak self] in
        self?.finish(
          .failure(RookOAuthError.callback("Sign-in timed out before the browser returned to Rook.")),
          callback: onCallback
        )
      }
      timeoutWorkItem = timeout
      queue.asyncAfter(deadline: .now() + 300, execute: timeout)
    } catch {
      DispatchQueue.main.async { onReady(.failure(error)) }
    }
  }

  public func cancel() {
    queue.async { [weak self] in
      self?.timeoutWorkItem?.cancel()
      self?.listener?.cancel()
      self?.listener = nil
      self?.didFinish = true
    }
  }

  private func receive(connection: NWConnection, callback: @escaping CallbackHandler) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
      guard let self else { return }
      if let error {
        connection.cancel()
        self.finish(
          .failure(RookOAuthError.callback("Rook could not read the OAuth callback: \(error.localizedDescription)")),
          callback: callback
        )
        return
      }

      guard let data,
        let request = String(data: data, encoding: .utf8),
        let firstLine = request.components(separatedBy: "\r\n").first
      else {
        self.respond(connection: connection, success: false)
        self.finish(.failure(RookOAuthError.callback("The OAuth callback was malformed.")), callback: callback)
        return
      }

      let parts = firstLine.split(separator: " ")
      guard parts.count >= 2,
        parts[0] == "GET",
        let url = URL(string: "http://127.0.0.1\(parts[1])"),
        url.path == "/oauth/callback"
      else {
        self.respond(connection: connection, success: false)
        return
      }

      self.respond(connection: connection, success: true)
      self.finish(.success(url), callback: callback)
    }
  }

  private func respond(connection: NWConnection, success: Bool) {
    let title = success ? "Rook is connected" : "Rook could not finish sign-in"
    let detail =
      success
      ? "You can close this tab and return to Rook."
      : "Close this tab and try the connection again from Rook."
    let body = """
      <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
      <body style="font:16px -apple-system;padding:48px;background:#fbf7ef;color:#171412">
      <h1 style="font-family:Georgia,serif">\(title)</h1><p>\(detail)</p></body></html>
      """
    let response = """
      HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(body.utf8.count)\r
      Connection: close\r
      \r
      \(body)
      """
    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
  }

  private func finish(_ result: Result<URL, Error>, callback: @escaping CallbackHandler) {
    guard !didFinish else { return }
    didFinish = true
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    listener?.cancel()
    listener = nil
    DispatchQueue.main.async { callback(result) }
  }
}
