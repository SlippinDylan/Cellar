import Foundation

enum AppDestination: Hashable {
    case overview
    case homebrew(HomebrewPage)
    case node(NodePage)
    case shell(ShellPage)
    case activity
    case settings

    var navigationTitle: String {
        switch self {
        case .overview: "概览"
        case .homebrew(let page): page == .overview ? "Homebrew" : "Homebrew · \(page.title)"
        case .node(let page): page == .overview ? "Node" : "Node · \(page.title)"
        case .shell(let page): page == .overview ? "Shell" : "Shell · \(page.title)"
        case .activity: "操作记录"
        case .settings: "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "快速查看 Homebrew、Node 和 Shell 的当前状态"
        case .homebrew(let page): page.subtitle
        case .node(let page): page.subtitle
        case .shell(let page): page.subtitle
        case .activity: "查看本次 App 会话中的刷新结果和错误"
        case .settings: "管理更新并查看 Cellar 版本信息"
        }
    }
}

enum HomebrewPage: String, CaseIterable, Identifiable {
    case overview
    case installed
    case upgrades
    case discover
    case doctor
    case configuration

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "概览"
        case .installed: "已安装"
        case .upgrades: "可升级"
        case .discover: "发现"
        case .doctor: "诊断"
        case .configuration: "配置"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .installed: "shippingbox"
        case .upgrades: "arrow.up.circle"
        case .discover: "safari"
        case .doctor: "stethoscope"
        case .configuration: "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "查看 Homebrew 的安装位置、版本与 Manager 快照"
        case .installed: "浏览已安装的 Formula 和 Cask"
        case .upgrades: "查看可以升级的 Homebrew 项目"
        case .discover: "查找可通过 Homebrew 安装的软件"
        case .doctor: "检查 Homebrew 环境和诊断结果"
        case .configuration: "查看 Homebrew 配置与运行环境"
        }
    }
}

enum NodePage: String, CaseIterable, Identifiable {
    case overview
    case packages
    case versions
    case registry
    case maintenance

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "概览"
        case .packages: "全局包"
        case .versions: "Node 版本"
        case .registry: "Registry"
        case .maintenance: "维护"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .packages: "shippingbox"
        case .versions: "point.3.connected.trianglepath.dotted"
        case .registry: "network"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "查看当前 Node/npm 环境、全局包和 registry 配置"
        case .packages: "管理当前 Node 环境的 npm 全局包"
        case .versions: "查看和管理 nvm 中的 Node 版本"
        case .registry: "查看和管理 npm registry 配置"
        case .maintenance: "检查缓存、日志和 Node 环境状态"
        }
    }
}

enum ShellPage: String, CaseIterable, Identifiable {
    case overview
    case ohMyZsh
    case extensions
    case maintenance

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "概览"
        case .ohMyZsh: "Oh My Zsh"
        case .extensions: "插件与主题"
        case .maintenance: "维护"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .ohMyZsh: "bolt"
        case .extensions: "puzzlepiece.extension"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "查看系统 Zsh、Oh My Zsh 与 Manager 快照"
        case .ohMyZsh: "查看和管理 Oh My Zsh"
        case .extensions: "查看 Shell 插件与主题"
        case .maintenance: "检查和维护 Shell 环境"
        }
    }
}
