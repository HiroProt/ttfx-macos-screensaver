// Repoint saved screen saver selections at wherever ttfx.saver now lives.
//
//   osascript -l JavaScript repoint-selection.js <Index.plist> <bundle> [--dry-run]
//
// macOS records the chosen screen saver as an absolute path, once per space
// and once per display — 27 entries on one ordinary Mac. Moving the bundle
// invalidates every one of them and the screen saver silently reverts to the
// system default. Re-picking it in System Settings only repairs the space and
// display you happen to be looking at, so the rest keep reverting for weeks.
//
// JavaScript for Automation rather than python3 or swift: both of those are
// Command Line Tools stubs on a Mac that has never seen Xcode, and an
// installer cannot ask someone to install developer tools. osascript is in
// the base system.
//
// Only entries whose module path ends in /ttfx.saver are touched, and only
// when they differ from where the bundle actually is, so this is a no-op on
// every install after the one that moves it.

ObjC.import('Foundation');

function run(argv) {
  const storePath = argv[0], target = argv[1];
  const dry = argv.indexOf('--dry-run') >= 0;
  const targetURL = $.NSURL.fileURLWithPath(target).absoluteString.js.replace(/\/$/, '');

  const data = $.NSData.dataWithContentsOfFile(storePath);
  if (!data || data.isNil()) { console.log('no store at ' + storePath); return 0; }
  const root = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(
      data, $.NSPropertyListMutableContainersAndLeaves, null, Ref());
  if (!root || root.isNil() || !root.allKeys) { console.log('store unreadable'); return 0; }

  let changed = 0;

  function isDict(o) { return o && !o.isNil() && o.allKeys !== undefined; }
  function isArray(o) { return o && !o.isNil() && o.allKeys === undefined && o.objectAtIndex !== undefined; }

  function visit(node) {
    if (isDict(node)) {
      for (const key of ObjC.deepUnwrap(node.allKeys)) {
        const value = node.objectForKey(key);
        if (key === 'Idle' && isDict(value)) changed += repoint(value);
        visit(value);
      }
    } else if (isArray(node)) {
      for (let i = 0; i < node.count; i++) visit(node.objectAtIndex(i));
    }
  }

  function repoint(idle) {
    const content = idle.objectForKey('Content');
    if (!isDict(content)) return 0;
    const choices = content.objectForKey('Choices');
    if (!isArray(choices) || choices.count === 0) return 0;

    let n = 0;
    for (let i = 0; i < choices.count; i++) {
      const choice = choices.objectAtIndex(i);
      if (!isDict(choice)) continue;
      const provider = choice.objectForKey('Provider');
      if (!provider || provider.isNil() || !String(provider.js).endsWith('screen-saver')) continue;
      const blob = choice.objectForKey('Configuration');
      if (!blob || blob.isNil() || blob.length === 0) continue;

      const cfg = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(
          blob, $.NSPropertyListMutableContainersAndLeaves, null, Ref());
      if (!isDict(cfg)) continue;
      const mod = cfg.objectForKey('module');
      if (!isDict(mod)) continue;
      const rel = mod.objectForKey('relative');
      if (!rel || rel.isNil()) continue;

      const url = String(rel.js).replace(/\/$/, '');
      // Ours, and somewhere other than where it now lives.
      if (!url.endsWith('/ttfx.saver') || url === targetURL) continue;

      mod.setObjectForKey(targetURL, 'relative');
      const out = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(
          cfg, $.NSPropertyListBinaryFormat_v1_0, 0, Ref());
      choice.setObjectForKey(out, 'Configuration');
      n++;
    }
    return n;
  }

  visit(root);
  if (changed === 0) { console.log('nothing to repoint'); return 0; }
  if (dry) { console.log(changed + ' entries would be repointed to ' + targetURL); return 0; }

  const out = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(
      root, $.NSPropertyListBinaryFormat_v1_0, 0, Ref());
  if (!out.writeToFileAtomically(storePath, true)) { console.log('write failed'); return 1; }
  console.log(changed + ' entries repointed to ' + targetURL);
  return 0;
}
