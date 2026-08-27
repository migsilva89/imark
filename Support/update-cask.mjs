#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs"

const [file, version, sha] = process.argv.slice(2)
if (!file || !version || !sha) {
  console.error("usage: Support/update-cask.mjs Casks/imark.rb VERSION SHA256")
  process.exit(2)
}

let text = readFileSync(file, "utf8")
for (const [key, value] of [["version", version], ["sha256", sha]]) {
  const pattern = new RegExp(`(^\\s*${key} ")[^"]*(")`, "m")
  if (!pattern.test(text)) {
    console.error(`no ${key} line in the cask`)
    process.exit(1)
  }
  text = text.replace(pattern, `$1${value}$2`)
}

if (!/^\s*auto_updates true$/m.test(text)) {
  const after = /(^\s*livecheck do[\s\S]*?^\s*end\n)/m
  if (!after.test(text)) {
    console.error("no livecheck block in the cask")
    process.exit(1)
  }
  text = text.replace(after, "$1\n  auto_updates true\n")
}

if (!/^\s*binary /m.test(text)) {
  const after = /(^\s*app "Imark\.app"\n)/m
  if (!after.test(text)) {
    console.error('no app "Imark.app" line in the cask')
    process.exit(1)
  }
  text = text.replace(
    after,
    '$1  binary "#{appdir}/Imark.app/Contents/Resources/imark"\n'
  )
}

writeFileSync(file, text)
