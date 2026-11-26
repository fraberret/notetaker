// Prove della logica Swift della pillola (senza interfaccia). Si eseguono con tests/test_swift.sh.
import Foundation

var verifiche = 0
var fallite = 0

func verifica(_ c: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    verifiche += 1
    if !c {
        fallite += 1
        print("FALLITA: \(msg) (\((file as NSString).lastPathComponent):\(line))")
    }
}

func fine() -> Never {
    if fallite > 0 {
        print("FALLITE \(fallite) su \(verifiche) verifiche")
        exit(1)
    }
    print("OK \(verifiche) verifiche")
    exit(0)
}

testLogica()
fine()
