"""Use this task's isolated signing identity without changing system trust."""
import json
import shlex
import subprocess
import sys

with open(sys.argv[1]) as handle:
    signing = json.load(handle)


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.replace(signing["password"], "[redacted]"))
    return result.stdout


search_list = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
try:
    run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *search_list, signing["keychain"]])
    run(["/usr/bin/security", "unlock-keychain", "-p", signing["password"], signing["keychain"]])
    run(["/usr/bin/codesign", "--force", "--deep", "--keychain", signing["keychain"], "--sign", signing["identity"], sys.argv[2]])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", sys.argv[2]])
finally:
    run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *search_list])
    run(["/usr/bin/security", "lock-keychain", signing["keychain"]])

print("Signed with the stable local PinBar identity; system trust unchanged.")
