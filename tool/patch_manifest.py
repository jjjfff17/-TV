#!/usr/bin/env python3
"""给 Flutter 生成的 AndroidManifest.xml 打补丁（CL-NAT-01）。

Flutter 的 release 模板默认不含 INTERNET 权限，media_kit 会因无法联网而黑屏。
另外部分片源是 http://，需要放开 cleartext。

用法：python3 tool/patch_manifest.py <AndroidManifest.xml 路径>
"""

import re
import sys


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: patch_manifest.py <AndroidManifest.xml>")

    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        src = f.read()

    perms = ""
    if "android.permission.INTERNET" not in src:
        perms += '    <uses-permission android:name="android.permission.INTERNET"/>\n'
    if "android.permission.WAKE_LOCK" not in src:
        perms += '    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n'

    if perms:
        src = src.replace("<application", perms + "    <application", 1)

    if "usesCleartextTraffic" not in src:
        src = src.replace(
            "<application",
            '<application android:usesCleartextTraffic="true"',
            1,
        )

    src = re.sub(r'android:label="[^"]*"', 'android:label="LibreTV"', src, count=1)

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)

    print("patched:", path)


if __name__ == "__main__":
    main()
