require '../src/window'
atom.initialize()
atom.restoreWindowDimensions()

require 'jasmine-json'
require '../vendor/jasmine-jquery'
path = require 'path'
_ = require 'underscore-plus'
fs = require 'fs-plus'
Grim = require 'grim'
KeymapManager = require '../src/keymap-extensions'

Config = require '../src/config'
{Point} = require 'text-buffer'
Project = require '../src/project'
Workspace = require '../src/workspace'
ServiceHub = require 'service-hub'
TextEditor = require '../src/text-editor'
TextEditorElement = require '../src/text-editor-element'
TokenizedBuffer = require '../src/tokenized-buffer'
TextEditorComponent = require '../src/text-editor-component'
pathwatcher = require 'pathwatcher'
clipboard = require '../src/safe-clipboard'

atom.themes.loadBaseStylesheets()
atom.themes.requireStylesheet '../static/jasmine'
atom.themes.initialLoadComplete = true

fixturePackagesPath = path.resolve(__dirname, './fixtures/packages')
atom.packages.packageDirPaths.unshift(fixturePackagesPath)
atom.keymaps.loadBundledKeymaps()
keyBindingsToRestore = atom.keymaps.getKeyBindings()
commandsToRestore = atom.commands.getSnapshot()
styleElementsToRestore = atom.styles.getSnapshot()

window.addEventListener 'core:close', -> window.close()
window.addEventListener 'beforeunload', ->
  atom.storeWindowDimensions()
  atom.saveSync()

document.querySelector('html').style.overflow = 'auto'
document.body.style.overflow = 'auto'

# Allow document.title to be assigned in specs without screwing up spec window title
documentTitle = null
Object.defineProperty document, 'title',
  get: -> documentTitle
  set: (title) -> documentTitle = title

Set.prototype.jasmineToString = ->
  result = "Set {"
  first = true
  @forEach (element) ->
    result += ", " unless first
    result += element.toString()
  first = false
  result + "}"

Set.prototype.isEqual = (other) ->
  if other instanceof Set
    return false if @size isnt other.size
    values = @values()
    until (next = values.next()).done
      return false unless other.has(next.value)
    true
  else
    false

jasmine.getEnv().addEqualityTester(_.isEqual) # Use underscore's definition of equality for toEqual assertions

if process.env.CI
  jasmine.getEnv().defaultTimeoutInterval = 60000
else
  jasmine.getEnv().defaultTimeoutInterval = 5000

specPackageName = null
specPackagePath = null
specProjectPath = null
isCoreSpec = false

{specDirectory, resourcePath} = atom.getLoadSettings()

if specDirectory
  specPackagePath = path.resolve(specDirectory, '..')
  try
    specPackageName = JSON.parse(fs.readFileSync(path.join(specPackagePath, 'package.json')))?.name
  specProjectPath = path.join(specDirectory, 'fixtures')

isCoreSpec = specDirectory is fs.realpathSync(__dirname)

beforeEach ->
  documentTitle = null
  projectPath = specProjectPath ? path.join(@specDirectory, 'fixtures')
  atom.packages.serviceHub = new ServiceHub
  atom.project = new Project(paths: [projectPath])
  atom.workspace = new Workspace()
  atom.keymaps.keyBindings = _.clone(keyBindingsToRestore)
  atom.commands.restoreSnapshot(commandsToRestore)
  atom.styles.restoreSnapshot(styleElementsToRestore)
  atom.views.clearDocumentRequests()

  atom.workspaceParentSelectorctor = '#jasmine-content'

  window.resetTimeouts()
  spyOn(_._, "now").andCallFake -> window.now
  spyOn(window, "setTimeout").andCallFake window.fakeSetTimeout
  spyOn(window, "clearTimeout").andCallFake window.fakeClearTimeout

  atom.packages.packageStates = {}

  serializedWindowState = null

  spyOn(atom, 'saveSync')
  atom.grammars.clearGrammarOverrides()

  spy = spyOn(atom.packages, 'resolvePackagePath').andCallFake (packageName) ->
    if specPackageName and packageName is specPackageName
      resolvePackagePath(specPackagePath)
    else
      resolvePackagePath(packageName)
  resolvePackagePath = _.bind(spy.originalValue, atom.packages)

  # prevent specs from modifying Atom's menus
  spyOn(atom.menu, 'sendToBrowserProcess')

  # reset config before each spec; don't load or save from/to `config.json`
  spyOn(Config::, 'load')
  spyOn(Config::, 'save')
  config = new Config({resourcePath, configDirPath: atom.getConfigDirPath()})
  atom.config = config
  atom.loadConfig()
  config.set "core.destroyEmptyPanes", false
  config.set "editor.fontFamily", "Courier"
  config.set "editor.fontSize", 16
  config.set "editor.autoIndent", false
  config.set "core.disabledPackages", ["package-that-throws-an-exception",
    "package-with-broken-package-json", "package-with-broken-keymap"]
  config.set "editor.useShadowDOM", true
  advanceClock(1000)
  window.setTimeout.reset()
  config.load.reset()
  config.save.reset()

  # make editor display updates synchronous
  TextEditorElement::setUpdatedSynchronously(true)

  spyOn(atom, "setRepresentedFilename")
  spyOn(pathwatcher.File.prototype, "detectResurrectionAfterDelay").andCallFake -> @detectResurrection()
  spyOn(TextEditor.prototype, "shouldPromptToSave").andReturn false

  # make tokenization synchronous
  TokenizedBuffer.prototype.chunkSize = Infinity
  spyOn(TokenizedBuffer.prototype, "tokenizeInBackground").andCallFake -> @tokenizeNextChunk()

  clipboardContent = 'initial clipboard content'
  spyOn(clipboard, 'writeText').andCallFake (text) -> clipboardContent = text
  spyOn(clipboard, 'readText').andCallFake -> clipboardContent

  addCustomMatchers(this)

afterEach ->
  atom.packages.deactivatePackages()
  atom.menu.template = []
  atom.contextMenu.clear()
  atom.notifications.clear()

  atom.workspace?.destroy()
  atom.workspace = null
  delete atom.state.workspace

  atom.project?.destroy()
  atom.project = null

  atom.themes.removeStylesheet('global-editor-styles')

  delete atom.state.packageStates

  document.getElementById('jasmine-content').innerHTML = '' unless window.debugContent

  jasmine.unspy(atom, 'saveSync')
  ensureNoPathSubscriptions()
  waits(0) # yield to ui thread to make screen update more frequently

ensureNoPathSubscriptions = ->
  watchedPaths = pathwatcher.getWatchedPaths()
  pathwatcher.closeAllWatchers()
  if watchedPaths.length > 0
    throw new Error("Leaking subscriptions for paths: " + watchedPaths.join(", "))

ensureNoDeprecatedFunctionsCalled = ->
  deprecations = Grim.getDeprecations()
  if deprecations.length > 0
    originalPrepareStackTrace = Error.prepareStackTrace
    Error.prepareStackTrace = (error, stack) ->
      output = []
      for deprecation in deprecations
        output.push "#{deprecation.originName} is deprecated. #{deprecation.message}"
        output.push _.multiplyString("-", output[output.length - 1].length)
        for stack in deprecation.getStacks()
          for {functionName, location} in stack
            output.push "#{functionName} -- #{location}"
        output.push ""
      output.join("\n")

    error = new Error("Deprecated function(s) #{deprecations.map(({originName}) -> originName).join ', '}) were called.")
    error.stack
    Error.prepareStackTrace = originalPrepareStackTrace

    throw error

emitObject = jasmine.StringPrettyPrinter.prototype.emitObject
jasmine.StringPrettyPrinter.prototype.emitObject = (obj) ->
  if obj.inspect
    @append obj.inspect()
  else
    emitObject.call(this, obj)

jasmine.unspy = (object, methodName) ->
  throw new Error("Not a spy") unless object[methodName].hasOwnProperty('originalValue')
  object[methodName] = object[methodName].originalValue

jasmine.attachToDOM = (element) ->
  jasmineContent = document.querySelector('#jasmine-content')
  jasmineContent.appendChild(element) unless jasmineContent.contains(element)

deprecationsSnapshot = null
jasmine.snapshotDeprecations = ->
  deprecationsSnapshot = _.clone(Grim.deprecations)

jasmine.restoreDeprecationsSnapshot = ->
  Grim.deprecations = deprecationsSnapshot

jasmine.useRealClock = ->
  jasmine.unspy(window, 'setTimeout')
  jasmine.unspy(window, 'clearTimeout')
  jasmine.unspy(_._, 'now')

addCustomMatchers = (spec) ->
  spec.addMatchers
    toBeInstanceOf: (expected) ->
      notText = if @isNot then " not" else ""
      this.message = => "Expected #{jasmine.pp(@actual)} to#{notText} be instance of #{expected.name} class"
      @actual instanceof expected

    toHaveLength: (expected) ->
      if not @actual?
        this.message = => "Expected object #{@actual} has no length method"
        false
      else
        notText = if @isNot then " not" else ""
        this.message = => "Expected object with length #{@actual.length} to#{notText} have length #{expected}"
        @actual.length is expected

    toExistOnDisk: (expected) ->
      notText = this.isNot and " not" or ""
      @message = -> return "Expected path '" + @actual + "'" + notText + " to exist."
      fs.existsSync(@actual)

    toHaveFocus: ->
      notText = this.isNot and " not" or ""
      if not document.hasFocus()
        console.error "Specs will fail because the Dev Tools have focus. To fix this close the Dev Tools or click the spec runner."

      @message = -> return "Expected element '" + @actual + "' or its descendants" + notText + " to have focus."
      element = @actual
      element = element.get(0) if element.jquery
      element is document.activeElement or element.contains(document.activeElement)

    toShow: ->
      notText = if @isNot then " not" else ""
      element = @actual
      element = element.get(0) if element.jquery
      @message = -> return "Expected element '#{element}' or its descendants#{notText} to show."
      element.style.display in ['block', 'inline-block', 'static', 'fixed']

window.waitsForPromise = (args...) ->
  if args.length > 1
    {shouldReject, timeout} = args[0]
  else
    shouldReject = false
  fn = _.last(args)

  window.waitsFor timeout, (moveOn) ->
    promise = fn()
    if shouldReject
      promise.catch.call(promise, moveOn)
      promise.then ->
        jasmine.getEnv().currentSpec.fail("Expected promise to be rejected, but it was resolved")
        moveOn()
    else
      promise.then(moveOn)
      promise.catch.call promise, (error) ->
        jasmine.getEnv().currentSpec.fail("Expected promise to be resolved, but it was rejected with: #{error?.message} #{jasmine.pp(error)}")
        moveOn()

window.resetTimeouts = ->
  window.now = 0
  window.timeoutCount = 0
  window.intervalCount = 0
  window.timeouts = []
  window.intervalTimeouts = {}

window.fakeSetTimeout = (callback, ms) ->
  id = ++window.timeoutCount
  window.timeouts.push([id, window.now + ms, callback])
  id

window.fakeClearTimeout = (idToClear) ->
  window.timeouts = window.timeouts.filter ([id]) -> id isnt idToClear

window.fakeSetInterval = (callback, ms) ->
  id = ++window.intervalCount
  action = ->
    callback()
    window.intervalTimeouts[id] = window.fakeSetTimeout(action, ms)
  window.intervalTimeouts[id] = window.fakeSetTimeout(action, ms)
  id

window.fakeClearInterval = (idToClear) ->
  window.fakeClearTimeout(@intervalTimeouts[idToClear])

window.advanceClock = (delta=1) ->
  window.now += delta
  callbacks = []

  window.timeouts = window.timeouts.filter ([id, strikeTime, callback]) ->
    if strikeTime <= window.now
      callbacks.push(callback)
      false
    else
      true

  callback() for callback in callbacks
