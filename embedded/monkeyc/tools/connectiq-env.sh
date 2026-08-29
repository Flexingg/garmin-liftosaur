#!/usr/bin/env bash
# Connect IQ tool wrappers for git-bash.
# The stock SDK wrappers build classpaths from MSYS paths (/c/...) which java
# cannot open; these pass native Windows paths. Source this file, then use
# monkeyc / connectiq / monkeydo / keytool.

SDK_BIN='C:\Users\Jonat\AppData\Roaming\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.2.0-2026-06-09-92a1605b2\bin'
SDK_BIN_UNIX='/c/Users/Jonat/AppData/Roaming/Garmin/ConnectIQ/Sdks/connectiq-sdk-win-9.2.0-2026-06-09-92a1605b2/bin'

monkeyc() {
    java -Xms1g -Dfile.encoding=UTF-8 -Dapple.awt.UIElement=true \
        -cp "$SDK_BIN\\monkeybrains.jar" com.garmin.monkeybrains.Monkeybrains "$@"
}

connectiq() {
    "$SDK_BIN_UNIX/simulator.exe" "$@" &
}

monkeydo() {
    java -classpath "$SDK_BIN\\monkeybrains.jar" \
        com.garmin.monkeybrains.monkeydodeux.MonkeyDoDeux \
        -f "$1" -d "$2" -s "$SDK_BIN\\shell.exe"
}

monkeydoctor() {
    java -Dfile.encoding=UTF-8 -cp "$SDK_BIN\\monkeybrains.jar" \
        com.garmin.monkeybrains.MonkeyDoctor "$@"
}

export -f monkeyc connectiq monkeydo monkeydoctor
export SDK_BIN
