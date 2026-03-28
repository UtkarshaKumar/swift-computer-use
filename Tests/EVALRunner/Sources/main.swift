import Foundation

let cases: [EvalCase] = [
    EVAL_SYS_001(),
    EVAL_SYS_002(),
    EVAL_SYS_003(),
    EVAL_SYS_004(),
    EVAL_SYS_005()
]

let runner = EvalRunner(cases: cases)
let results = runner.run()
printSummary(results)