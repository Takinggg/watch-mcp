import AppKit

/// Dock icon (default) or menu bar only.
@MainActor
enum DockIcon {
    static func apply() {
        NSApp.setActivationPolicy(Settings.showInDock ? .regular : .accessory)
    }
}

/// The menus every Mac app has. They are also what makes ⌘C, ⌘V and ⌘A work in text fields,
/// ⌘W close a window and ⌘Q quit.
@MainActor
enum MainMenu {
    static func make(target: AnyObject, settings: Selector, quit: Selector) -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, "WatchRecorder")
        app.addItem(withTitle: L.t("About WatchRecorder", "À propos de WatchRecorder", "WatchRecorder에 관하여"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item(L.t("Settings…", "Réglages…", "설정…"), settings, ",", target: target))
        app.addItem(.separator())
        app.addItem(withTitle: L.t("Hide WatchRecorder", "Masquer WatchRecorder", "WatchRecorder 가리기"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: L.t("Hide Others", "Masquer les autres", "기타 가리기"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L.t("Show All", "Tout afficher", "모두 보기"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item(L.t("Quit WatchRecorder", "Quitter WatchRecorder", "WatchRecorder 종료"), quit, "q", target: target))

        let edit = submenu(of: main, L.t("Edit", "Édition", "편집"))
        edit.addItem(withTitle: L.t("Undo", "Annuler", "실행 취소"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L.t("Redo", "Rétablir", "실행 복귀"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L.t("Cut", "Couper", "오려두기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L.t("Copy", "Copier", "복사하기"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L.t("Paste", "Coller", "붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L.t("Select All", "Tout sélectionner", "전체 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = submenu(of: main, L.t("Window", "Fenêtre", "윈도우"))
        window.addItem(withTitle: L.t("Minimize", "Réduire", "최소화"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L.t("Close", "Fermer", "닫기"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(of main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
