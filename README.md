# Bar - macOS Taskbar with Per-Space Windows

Bar is a macOS utility app that creates a taskbar similar to Windows, showing all open windows and allowing you to switch between them. The app now supports **per-space window management** with caching, meaning each space gets its own taskbar window that remembers which windows were open on that space.

## Features

### Per-Space Window Management
- **One taskbar per space**: Each Mission Control space gets its own taskbar window
- **Window caching**: When you switch back to a space, the taskbar remembers which windows were open
- **Full screen detection**: Taskbar automatically hides on full screen spaces
- **Space switching**: Smooth transitions between spaces with appropriate taskbar visibility

### Window Management
- **Real-time window detection**: Uses Accessibility APIs to detect window changes
- **Window activation**: Click any window in the taskbar to bring it to front
- **Window minimization**: Right-click to minimize windows
- **Focus tracking**: Highlights the currently active window

### Keyboard Shortcuts
- **Window switching**: Use keyboard shortcuts to quickly switch between windows
- **Key assignment**: Automatically assigns keyboard shortcuts to windows based on app names

## Architecture

### Core Components

1. **SpaceManager** (`SpaceManager.swift`)
   - Detects current space and available spaces
   - Manages per-space window caching
   - Handles full screen space detection
   - Observes space changes

2. **WindowManager** (`WindowManager.swift`)
   - Manages window detection and tracking
   - Integrates with SpaceManager for per-space caching
   - Handles window activation and focus

3. **NativeDesktopBridge** (`NativeDesktopBridge.swift`)
   - Low-level window management using Accessibility APIs
   - Real-time window event monitoring
   - Window manipulation (activate, minimize, resize)

4. **BarApp** (`BarApp.swift`)
   - Creates multiple taskbar windows (one per space)
   - Manages window visibility based on current space
   - Handles space switching events

### How Per-Space Windows Work

1. **Space Detection**: The app detects available spaces and the current active space
2. **Window Creation**: Creates one taskbar window for each non-full-screen space
3. **Caching**: Each space maintains its own cache of window information
4. **Space Switching**: When you switch spaces, the appropriate taskbar window is shown
5. **Window Persistence**: When you return to a space, the cached window list is restored

### Window Caching

- **Cache Duration**: 30 seconds per space
- **Cache Invalidation**: Automatically invalidated when windows change
- **Memory Management**: Caches are cleared when spaces are removed

## Installation

1. Clone the repository
2. Open `Bar.xcodeproj` in Xcode
3. Build and run the project
4. Grant accessibility permissions when prompted

## Permissions Required

- **Accessibility**: Required for window detection and management
- **Input Monitoring**: Required for keyboard shortcuts (optional)

## Development

### Building the Project

Always use xcodebuild for building to ensure proper indexing:

```bash
xcodebuild -project Bar.xcodeproj -scheme Bar -configuration Debug build
```

### Key Files

- `SpaceManager.swift`: Space detection and caching logic
- `WindowManager.swift`: Window management and UI updates
- `BarApp.swift`: Main app delegate and window creation
- `NativeDesktopBridge.swift`: Low-level window APIs
- `ContentView.swift`: Taskbar UI

### Logging

The app includes comprehensive logging with categories:
- `SpaceManagement`: Space detection and caching
- `WindowManager`: Window tracking and updates
- `FocusSwitching`: Window focus changes
- `Accessibility`: Permission and API status

Enable logging categories in the app's debug interface.

## Limitations

- **Space Detection**: Currently uses a simplified approach based on screens. For more accurate Mission Control space detection, private APIs would be needed.
- **Window Assignment**: Windows are assigned to spaces based on their current position. More sophisticated space detection would improve this.
- **Full Screen Apps**: Detection of full screen apps relies on Accessibility APIs and may not catch all cases.

## Future Improvements

- **Private APIs**: Use private Mission Control APIs for more accurate space detection
- **Space Persistence**: Save space configurations across app restarts
- **Custom Space Names**: Allow users to name their spaces
- **Space-Specific Settings**: Different taskbar configurations per space

## Troubleshooting

### Taskbar Not Appearing
1. Check accessibility permissions in System Preferences
2. Ensure the app is not running in full screen mode
3. Check console logs for error messages

### Windows Not Updating
1. Verify accessibility permissions are granted
2. Check if the space is full screen (taskbar will be hidden)
3. Restart the app to refresh window observers

### Performance Issues
1. Reduce cache timeout in `SpaceManager.swift`
2. Disable unnecessary logging categories
3. Check for excessive window change events 