// One window, one box per field. Run by dialog_capture_many (dialog.sh) as:
//   osascript -l JavaScript dialog-many.js <out-dir> <title> <label> <hidden|visible> [<label> <hidden|visible> ...]
// Writes each value to <out-dir>/<n> (1-based, in field order) and prints "ok",
// or prints "cancelled" and writes nothing. Values never reach stdout or stderr.
ObjC.import('Cocoa')

function run(argv) {
  const outDir = argv[0]
  const title = argv[1]
  const specs = []
  for (let i = 2; i + 1 < argv.length; i += 2) specs.push({ label: argv[i], visible: argv[i + 1] === 'visible' })
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

  if (alert.runModal !== $.NSAlertFirstButtonReturn) return 'cancelled'

  fields.forEach((field, i) => {
    const ok = field.stringValue.writeToFileAtomicallyEncodingError(outDir + '/' + (i + 1), true, $.NSUTF8StringEncoding, null)
    if (!ok) throw new Error('ADAPTER_ERROR: could not write field ' + (i + 1))
  })
  return 'ok'
}
