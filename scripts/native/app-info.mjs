// Keep bundle metadata generation importable so drag type declarations are tested.
export const usageDescriptions = {
 NSMicrophoneUsageDescription: 'neuraOS uses the microphone when websites you allow record audio, such as calls and voice input.',
 NSCameraUsageDescription: 'neuraOS uses the camera when websites you allow capture video, such as video calls.',
 NSAudioCaptureUsageDescription: 'neuraOS captures system audio when you share your screen or a window with sound on a website.',
 NSLocationUsageDescription: 'neuraOS uses your location when websites you allow ask for it, such as maps.',
 NSLocationWhenInUseUsageDescription: 'neuraOS uses your location when websites you allow ask for it, such as maps.',
 NSLocalNetworkUsageDescription: 'neuraOS connects to devices and servers on your local network when you open their addresses.',
 NSBluetoothAlwaysUsageDescription: 'neuraOS uses Bluetooth when websites use nearby devices for sign-in, such as passkeys on your phone.',
};
export function appInfoPlist({bundleId, version, build, dataDirectory, port, sparkleKeys = ''}) {
const escape=value=>value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
const extra=(dataDirectory?`<key>NeuraDataDirectory</key><string>${escape(dataDirectory)}</string>`:'')+(port?`<key>NeuraEndpoint</key><string>http://127.0.0.1:${Number(port)}</string>`:'');
const dragTypes = `<key>UTExportedTypeDeclarations</key><array>${[
 ['com.neuraos.sidebar-project', 'neuraOS Sidebar Project'],
 ['com.neuraos.sidebar-space', 'neuraOS Sidebar Space'],
].map(([id, description]) => `<dict><key>UTTypeIdentifier</key><string>${id}</string><key>UTTypeDescription</key><string>${description}</string><key>UTTypeConformsTo</key><array><string>public.data</string></array><key>UTTypeTagSpecification</key><dict><key>com.apple.nspboard-type</key><array><string>${id}</string></array></dict></dict>`).join('')}</array>`;
// macOS kills the whole app (TCC privacy violation) the moment a website reaches
// a protected resource whose usage string is missing, so declare every one a
// browser can trigger. Site-level consent stays with Chromium's own prompts.
const usage = Object.entries(usageDescriptions).map(([key, text]) => `<key>${key}</key><string>${escape(text)}</string>`).join('');
return `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>NeuraOS</string><key>CFBundleIdentifier</key><string>${escape(bundleId)}</string><key>CFBundleName</key><string>neuraOS</string><key>CFBundleDisplayName</key><string>neuraOS</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>${escape(version)}</string><key>CFBundleVersion</key><string>${build}</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/>${usage}<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>${dragTypes}${extra}${sparkleKeys}</dict></plist>`;
}
