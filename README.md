![](banner.jpg)

# DockLock

DockLock is a lightweight macOS menu bar utility that prevents your Dock from migrating to a secondary display. If you use multiple monitors, you've likely experienced the Dock unexpectedly jumping to a non-primary screen when your cursor ventures too close to the edge. DockLock solves this by keeping your Dock anchored to your primary display at all times.

---

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools or a full Xcode installation
- **Accessibility permission** (required for blocking mode — see [Permissions](#permissions))

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/DockLock.git
cd DockLock
```

### 2. Build and install

To install DockLock to `/Applications` (recommended, and required for Launch at Login):

```bash
make install
```

To simply build and launch without installing:

```bash
make run
```

---

## Granting Accessibility Permission

DockLock requires Accessibility access to function in blocking mode.

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Click the **+** button and add **DockLock**
3. Ensure the toggle next to DockLock is **enabled**

DockLock will prompt you on first launch and poll until permission is granted.

---

## Usage

Once launched, DockLock runs silently in the menu bar with no Dock icon. There is nothing to configure — it works automatically in the background.

### Menu Bar Icon

Click the DockLock icon in the menu bar to access options such as quitting the app.

### Launch at Login

To have DockLock start automatically when you log in:

1. First, install the app to `/Applications` using `make install`
2. Open **System Settings** → **General** → **Login Items**
3. Click **+** and add **DockLock** from your `/Applications` folder

---

## Build Commands

| Command | Description |
|---|---|
| `make run` | Build, bundle, sign, and launch DockLock |
| `make install` | Build and install to `/Applications` |
| `make clean` | Remove all build artifacts |
| `make uninstall` | Remove DockLock from `/Applications` |

---

## Uninstalling

To remove DockLock from your system:

```bash
make uninstall
```

Then remove it from **Login Items** in System Settings if you had enabled it there, and revoke its **Accessibility** permission if desired.

---

## License

This project is licensed under [CC BY-NC 4.0](https://darren-static.waft.dev/license) - free to use and modify, but no commercial use without permission.