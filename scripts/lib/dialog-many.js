// One window, one box per field. Run by dialog_capture (dialog.sh) as:
//   osascript -l JavaScript dialog-many.js <title> <key> <label> <hidden|visible> [<key> <label> <hidden|visible> ...]
// On Save, writes one JSON object {"<key>": "<value>", ...} to stdout, no newline, and exits 0.
// The caller pipes that stdout straight into the sealed slot (`f7 secret seal capture`): no
// value is written to a file. On Cancel, or a box left empty, writes nothing to stdout, says
// why on stderr and exits 4.
ObjC.import('Cocoa')
ObjC.import('stdlib')

function say(stream, text) {
  stream.writeData($(text).dataUsingEncoding($.NSUTF8StringEncoding))
}

function run(argv) {
  const title = argv[0]
  const specs = []
  for (let i = 1; i + 2 < argv.length; i += 3) specs.push({ key: argv[i], label: argv[i + 1], visible: argv[i + 2] === 'visible' })
  if (specs.length === 0) throw new Error('USAGE_ERROR: no fields')

  const app = $.NSApplication.sharedApplication
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory)

  // osascript has no menu bar, so Cmd+V and friends reach no field without an Edit menu.
  const edit = $.NSMenu.alloc.initWithTitle('Edit')
  for (const [name, action, key] of [['Undo', 'undo:', 'z'], ['Cut', 'cut:', 'x'], ['Copy', 'copy:', 'c'], ['Paste', 'paste:', 'v'], ['Select All', 'selectAll:', 'a']]) {
    edit.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(name, action, key))
  }
  const editItem = $.NSMenuItem.alloc.init
  editItem.submenu = edit
  const menu = $.NSMenu.alloc.init
  menu.addItem(editItem)
  app.mainMenu = menu

  const width = 340
  const rowHeight = 54
  const view = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, width, rowHeight * specs.length))
  const fields = specs.map((spec, i) => {
    const y = rowHeight * (specs.length - 1 - i)
    const label = $.NSTextField.labelWithString(spec.label + (spec.visible ? '' : ' (hidden)'))
    label.frame = $.NSMakeRect(0, y + 30, width, 18)
    const field = (spec.visible ? $.NSTextField : $.NSSecureTextField).alloc.initWithFrame($.NSMakeRect(0, y + 4, width, 24))
    view.addSubview(label)
    view.addSubview(field)
    return field
  })
  fields.forEach((field, i) => { field.nextKeyView = fields[(i + 1) % fields.length] })

  const alert = $.NSAlert.alloc.init
  alert.messageText = title
  alert.informativeText = 'Tab moves to the next box.'
  alert.addButtonWithTitle('Save')
  alert.addButtonWithTitle('Cancel')
  alert.accessoryView = view
  alert.window.initialFirstResponder = fields[0]
  app.activateIgnoringOtherApps(true)
  // Above every other window, even when macOS declines to make osascript the active app.
  alert.layout
  alert.window.level = $.NSStatusWindowLevel
  alert.window.orderFrontRegardless
  alert.window.makeKeyAndOrderFront(null)

  if (alert.runModal !== $.NSAlertFirstButtonReturn) {
    say($.NSFileHandle.fileHandleWithStandardError, 'CANCELLED\n')
    $.exit(4)
  }

  const values = {}
  specs.forEach((spec, i) => { values[spec.key] = fields[i].stringValue.js })
  const empty = specs.find((spec) => values[spec.key] === '')
  if (empty) {
    say($.NSFileHandle.fileHandleWithStandardError, "CANCELLED: '" + empty.label + "' was left empty\n")
    $.exit(4)
  }
  say($.NSFileHandle.fileHandleWithStandardOutput, JSON.stringify(values))
}
