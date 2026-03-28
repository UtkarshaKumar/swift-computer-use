protocol EvalCase {
    var id: String { get }
    var name: String { get }
    func run() -> EvalResult
}