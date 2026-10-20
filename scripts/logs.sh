#!/usr/bin/env bash
# Stream the app's unified-log output.
exec log stream --style compact --predicate 'subsystem == "com.ashish.heyclickyclone"' --level debug
