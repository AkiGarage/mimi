ObjC.import("Cocoa");
ObjC.import("Foundation");

const app = $.NSApplication.sharedApplication;
bestEffort("activateApplication", () => {
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
  app.activateIgnoringOtherApps(true);
});

const buttonReturnBase = 1000;
const supportDir = `${ObjC.unwrap($.NSHomeDirectory())}/Library/Application Support/Mimi`;
const configuredPositionPath = envString("MIMI_SETUP_DIALOG_POSITION_PATH");
const positionPath = configuredPositionPath || `${supportDir}/setup-dialog-position.json`;
const cancelResult = "__MIMI_DIALOG_CANCELLED__";

function run(argv) {
  const mode = String(argv[0] || "alert");
  if (mode === "--self-test" || mode === "self-test") {
    runSelfTest();
    return;
  }

  const title = String(argv[1] || "Mimi Setup");
  const message = String(argv[2] || "");
  const defaultText = String(argv[3] || "");
  const buttons = parseButtons(argv[4]);

  try {
    const result = showDialog({ mode, title, message, defaultText, buttons });
    if (result === cancelResult) {
      $.exit(1);
    }
    if (result !== undefined && result !== null) {
      console.log(result);
    }
  } catch (error) {
    writeStderr(`__MIMI_DIALOG_HELPER_FAILED__ ${String(error)}`);
    $.exit(2);
  }
}

function parseButtons(value) {
  const text = String(value || "");
  if (!text) return ["OK"];
  return text.split("|").filter((item) => item.length > 0);
}

function showDialog(options) {
  const alert = $.NSAlert.alloc.init();
  alert.setMessageText($(options.title));
  alert.setInformativeText($(options.message));
  for (const button of options.buttons) {
    alert.addButtonWithTitle($(button));
  }

  const input = makeInput(options);
  if (input) {
    alert.setAccessoryView(input);
  }

  const window = alert.window;
  bestEffort("moveWindowToSavedOrDefaultPosition", () => {
    moveWindowToSavedOrDefaultPosition(window);
  });
  const response = Number(alert.runModal());
  bestEffort("saveWindowPosition", () => {
    saveWindowPosition(window);
  });

  const buttonIndex = response - buttonReturnBase;
  const button = options.buttons[buttonIndex] || "";
  if (button === "Cancel" || button === "キャンセル") {
    return cancelResult;
  }
  if (options.mode === "choice") return button;
  if (input) return ObjC.unwrap(input.stringValue);
  return "";
}

function bestEffort(_label, callback) {
  try {
    return callback();
  } catch (_) {
    return null;
  }
}

function makeInput(options) {
  if (options.mode !== "prompt-hidden" && options.mode !== "prompt-text" && options.mode !== "copyable") {
    return null;
  }
  const fieldClass = options.mode === "prompt-hidden" ? $.NSSecureTextField : $.NSTextField;
  const field = fieldClass.alloc.initWithFrame($.NSMakeRect(0, 0, 460, 24));
  field.setStringValue($(options.defaultText));
  field.setEditable(options.mode !== "copyable");
  field.setSelectable(true);
  return field;
}

function moveWindowToSavedOrDefaultPosition(window) {
  if (!window) return;
  const frame = readWindowFrame(window);
  if (!frame) return;
  const point = clampPoint(loadSavedPosition() || defaultPosition(frame), frame);
  window.setFrameOrigin($.NSMakePoint(point.x, point.y));
}

function defaultPosition(frame) {
  const visible = visibleFrame();
  return {
    x: visible.origin.x + Math.max(24, Math.floor((visible.size.width - frame.size.width) / 2)),
    y: visible.origin.y + visible.size.height - frame.size.height - 90,
  };
}

function clampPoint(point, frame) {
  const visible = visibleFrame();
  const minX = visible.origin.x + 8;
  const maxX = visible.origin.x + visible.size.width - frame.size.width - 8;
  const minY = visible.origin.y + 8;
  const maxY = visible.origin.y + visible.size.height - frame.size.height - 8;
  return {
    x: Math.min(Math.max(Number(point.x), minX), Math.max(minX, maxX)),
    y: Math.min(Math.max(Number(point.y), minY), Math.max(minY, maxY)),
  };
}

function visibleFrame() {
  try {
    const screen = $.NSScreen.mainScreen;
    if (screen) return screen.visibleFrame;
  } catch (_) {
  }
  return {
    origin: { x: 0, y: 0 },
    size: { width: 1440, height: 900 },
  };
}

function loadSavedPosition() {
  return readJsonPosition(positionPath);
}

function readJsonPosition(filePath) {
  try {
    const text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
      $(filePath),
      $.NSUTF8StringEncoding,
      undefined
    ));
    const value = JSON.parse(text);
    if (Number.isFinite(value.x) && Number.isFinite(value.y)) return value;
  } catch (_) {
  }
  return null;
}

function saveWindowPosition(window) {
  if (!window) return;
  const frame = readWindowFrame(window);
  if (!frame) return;
  writeJsonPosition(positionPath, {
    x: Math.round(Number(frame.origin.x)),
    y: Math.round(Number(frame.origin.y)),
  });
}

function writeJsonPosition(filePath, point) {
  const text = JSON.stringify({
    x: Math.round(Number(point.x)),
    y: Math.round(Number(point.y)),
  });
  const directory = dirname(filePath);
  $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
    $(directory),
    true,
    undefined,
    undefined
  );
  const ok = $(text).writeToFileAtomicallyEncodingError(
    $(filePath),
    true,
    $.NSUTF8StringEncoding,
    null
  );
  if (!ok) throw new Error("position write failed");
}

function readWindowFrame(window) {
  const candidates = [];
  try {
    candidates.push(window.frame);
  } catch (_) {
  }
  try {
    candidates.push(window.frame());
  } catch (_) {
  }
  for (const frame of candidates) {
    if (isUsableFrame(frame)) return frame;
  }
  return null;
}

function isUsableFrame(frame) {
  return Boolean(
    frame &&
    frame.origin &&
    frame.size &&
    Number.isFinite(Number(frame.origin.x)) &&
    Number.isFinite(Number(frame.origin.y)) &&
    Number.isFinite(Number(frame.size.width)) &&
    Number.isFinite(Number(frame.size.height))
  );
}

function dirname(filePath) {
  const index = String(filePath).lastIndexOf("/");
  if (index <= 0) return ".";
  return String(filePath).slice(0, index);
}

function envString(name) {
  try {
    const value = $.NSProcessInfo.processInfo.environment.objectForKey($(name));
    if (value) return ObjC.unwrap(value);
  } catch (_) {
  }
  return "";
}

function writeStderr(message) {
  try {
    const data = $(String(message) + "\n").dataUsingEncoding($.NSUTF8StringEncoding);
    $.NSFileHandle.fileHandleWithStandardError.writeData(data);
  } catch (_) {
  }
}

function runSelfTest() {
  const parsed = parseButtons("A|B|C");
  if (parsed.length !== 3 || parsed[0] !== "A" || parsed[2] !== "C") {
    throw new Error("parseButtons failed");
  }
  const fallbackFrame = { origin: { x: 0, y: 0 }, size: { width: 320, height: 180 } };
  const point = defaultPosition(fallbackFrame);
  if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) {
    throw new Error("defaultPosition failed");
  }
  const clamped = clampPoint({ x: -999999, y: -999999 }, fallbackFrame);
  if (!Number.isFinite(clamped.x) || !Number.isFinite(clamped.y)) {
    throw new Error("clampPoint failed");
  }
  const testPositionPath = `${positionPath}.self-test`;
  writeJsonPosition(testPositionPath, { x: 123, y: 456 });
  const saved = readJsonPosition(testPositionPath);
  if (!saved || saved.x !== 123 || saved.y !== 456) {
    throw new Error("position read/write failed");
  }
  bestEffort("removeSelfTestPosition", () => {
    $.NSFileManager.defaultManager.removeItemAtPathError($(testPositionPath), undefined);
  });
  bestEffort("loadSavedPosition", () => loadSavedPosition());
  console.log(`PASS setup-dialog-helper self-test (${positionPath})`);
}
