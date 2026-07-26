import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand(
            "ntfy.depCheck",
            [
                "sh",
                "-c",
                "command -v curl >/dev/null && command -v secret-tool >/dev/null && command -v base64 >/dev/null"
            ],
            (stdout, exitCode) => {
                if (exitCode === 0) {
                    done(null)
                    return
                }
                done({
                    "title": "Missing dependencies for dms-ntfy",
                    "details": "'curl', 'secret-tool' (libsecret), and 'base64' are required on PATH. Install them and re-enable this plugin."
                })
            }
        )
    }
}
