import Foundation

// Entry point: parse argv, run the command against the live dependencies,
// write results verbatim, exit. All logic lives in Sources/Core (also compiled
// into the test target, which drives runCommand() with fakes).

let result = runCommand(Array(CommandLine.arguments.dropFirst()), .live)
FileHandle.standardOutput.write(Data(result.stdout.utf8))
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.exitCode)
