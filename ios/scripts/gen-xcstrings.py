#!/usr/bin/env python3
"""Generate Localizable.xcstrings and InfoPlist.xcstrings for Oppi."""
import json
import sys
from pathlib import Path

# ─── Localizable strings: English key → zh-Hans translation ───
# None = skip zh-Hans (brand names, universal notation)
# Key format: matches what SwiftUI auto-extracts
#   Text("foo")              → key: "foo"
#   Text("\(count) items")   → key: "%lld items"   (Int → %lld)
#   Text("\(name) said hi")  → key: "%@ said hi"   (String → %@)

strings: dict[str, str | None] = {
    # ── Onboarding ──
    "Control your pi agents\nfrom your phone.": "在手机上控制你的\npi 智能体。",
    "Scan QR Code": "扫描二维码",
    "Enter manually": "手动输入",
    "Connect to Server": "连接到服务器",
    "Testing connection…": "正在测试连接…",
    "Connected!": "已连接！",
    "Connection failed": "连接失败",
    "Try Again": "重试",
    "Back to current server": "返回当前服务器",
    "Connect Manually": "手动连接",
    "Server": "服务器",
    "Host (e.g. my-mac.local)": "主机（例如 my-mac.local）",
    "Port": "端口",
    "Auth": "认证",
    "Token": "令牌",
    "Name": "名称",
    "Connect": "连接",

    # ── What's New ──
    "What's New": "新功能",
    "in Oppi": "Oppi 更新",
    "Continue": "继续",
    "TLS": "TLS",
    "Connections are pinned to your server's TLS certificate.": "连接已绑定到服务器的 TLS 证书。",
    "Glass Chat Interface": "毛玻璃聊天界面",
    "Chat scrolls behind translucent bars with soft edge effects.": "聊天内容在半透明栏后滚动，带有柔和边缘效果。",
    "Thinking Trace": "思考轨迹",
    "Scrollable live preview while the model thinks. Tap to read the full trace.": "模型思考时可滚动实时预览。点击查看完整轨迹。",
    "Voice Input": "语音输入",
    "On-device speech-to-text. Tap the mic to dictate prompts.": "设备端语音转文字。点击麦克风口述提示词。",

    # ── Settings ──
    "Settings": "设置",
    "Servers": "服务器",
    "Rename": "重命名",
    "Remove": "移除",
    "Add Server": "添加服务器",
    "Appearance": "外观",
    "Sessions": "会话",
    "Experiments": "实验功能",
    "Cache": "缓存",
    "Clear Local Cache": "清除本地缓存",
    "About": "关于",
    "Rename Server": "重命名服务器",
    "Save": "保存",
    "Cancel": "取消",
    "Biometric Approval": "生物识别审批",
    "All permission approvals require %@. Deny is always one tap.": "所有权限审批需要%@验证。拒绝始终只需轻点一下。",
    "All permissions can be approved with a simple tap.": "所有权限都可以轻点审批。",
    "Connected": "已连接",
    "Connecting…": "连接中…",
    "Reconnecting…": "重新连接中…",
    "Offline": "离线",
    "Import Theme": "导入主题",
    "No themes found on server.\nAsk the agent to create one!": "服务器上未找到主题。\n让智能体创建一个吧！",
    "Remove Server": "移除服务器",
    "Remove Last Server": "移除最后一台服务器",

    # ── Workspaces ──
    "Workspaces": "工作区",
    "No workspaces": "暂无工作区",
    "Unreachable": "无法连接",
    "No sessions": "暂无会话",
    "Edit Workspace": "编辑工作区",
    "Identity": "标识",
    "Skills": "技能",
    "Loading skills…": "正在加载技能…",
    "Create": "创建",
    "Enabled Skills": "已启用技能",
    "No skills enabled": "未启用任何技能",
    "All skills enabled": "已启用所有技能",
    "Disabled Skills": "已禁用技能",
    "Host Working Directory": "主机工作目录",
    "Host process current directory": "主机进程当前目录",
    "Git Status": "Git 状态",
    "Shows branch, dirty files, and change stats in chat view": "在聊天视图中显示分支、未提交文件和变更统计",
    "Memory": "记忆",
    "Same namespace across workspaces shares memory": "跨工作区相同命名空间共享记忆",
    "Extensions": "扩展",
    "Named extensions from ~/.pi/agent/extensions.": "来自 ~/.pi/agent/extensions 的具名扩展。",
    "Loading available extensions…": "正在加载可用扩展…",
    "No discoverable extensions found.": "未发现可用扩展。",
    "System Prompt": "系统提示词",
    "Appended to the base agent prompt": "追加到基础智能体提示词",
    "Manage Workspaces": "管理工作区",
    "Stop": "停止",
    "Resume": "恢复",
    "Delete": "删除",
    "Tap + to create a workspace.": "点击 + 创建工作区。",
    "Tap + to create one.": "点击 + 创建一个。",
    "Pair with a server to get started.": "配对服务器以开始使用。",
    "Tap + to start a new session in this workspace.": "点击 + 在此工作区开始新会话。",
    "Try a different session name.": "尝试不同的会话名称。",
    "Search session name": "搜索会话名称",
    "Error": "错误",
    "%lld skills": "%lld 个技能",
    "New Workspace on %@": "%@ 上的新工作区",
    "%lld active": "%lld 个活跃",
    "%lld stopped": "%lld 个已停止",
    "Resuming session...": "正在恢复会话…",
    "Creating session...": "正在创建会话…",
    "Files": "文件",
    "Skills haven't loaded yet.": "技能尚未加载。",
    "Enabled (%lld)": "已启用 (%lld)",
    "Available": "可用",

    # ── Safety Rules (Policy) ──
    "Safety Rules": "安全规则",
    "Default Fallback": "默认兜底策略",
    "Allow": "允许",
    "Ask": "询问",
    "Deny": "拒绝",
    "Remembered Rules": "已记忆规则",
    "No remembered rules for this workspace.": "此工作区暂无已记忆规则。",
    "Revoke": "撤销",
    "Recent Decisions": "最近决策",
    "No recent policy decisions.": "暂无最近的策略决策。",
    "Add Rule": "添加规则",
    "Rule": "规则",
    "Match": "匹配",
    "Policy Error": "策略错误",
    "OK": "好",
    "Add Remembered Rule": "添加记忆规则",
    "Edit Remembered Rule": "编辑记忆规则",
    "Showing 25 of %lld rules": "显示 %lld 条规则中的 25 条",
    "Showing 30 of %lld entries": "显示 %lld 条记录中的 30 条",
    "Remove remembered rule %@?": "确定撤销记忆规则 %@ 吗？",
    "Expires %@": "%@ 后过期",

    # ── Chat ──
    "Rename Session": "重命名会话",
    "Switch model in active session?": "在活跃会话中切换模型？",
    "Keep Current": "保持当前",
    "Switch Anyway": "仍然切换",
    "Switching to %@ now invalidates prompt caching for this conversation, which can increase cost and latency. Prefer switching when starting a new session.": "切换到 %@ 会使此对话的提示缓存失效，可能增加成本和延迟。建议在开始新会话时切换。",
    "Compact Context": "压缩上下文",
    "Compact": "压缩",
    "This will summarize the conversation to free up context window space. The summary replaces earlier messages.": "这将总结对话以释放上下文窗口空间。摘要将替换之前的消息。",
    "Copy Session ID": "复制会话 ID",
    "Done": "完成",
    "Send": "发送",
    "Photo Library": "相册",
    "Camera": "相机",
    "Stopping…": "正在停止…",
    "Force Stop Session": "强制停止会话",
    "Session ended": "会话已结束",
    "Models": "模型",
    "Search models…": "搜索模型…",
    "Recent": "最近使用",
    "current": "当前",
    "Server returned no models.": "服务器未返回任何模型。",
    "Steer Agent": "引导智能体",
    "Compose": "编写",
    "Steer agent…": "引导智能体…",
    "Message…": "消息…",
    "Resuming…": "恢复中…",
    "Resume Session": "恢复会话",
    "Upload Client Logs": "上传客户端日志",
    "Uploading Client Logs…": "正在上传客户端日志…",
    "Submit": "提交",

    # ── Permissions ──
    "Permission Request": "权限请求",
    "No expiry": "无时限",
    "Full action": "完整操作",
    "Deny All (%lld)": "全部拒绝 (%lld)",
    "More options": "更多选项",
    "Reject": "拒绝",
    "Approve": "批准",
    "Allow this session": "本次会话允许",
    "Allow always": "始终允许",
    "Deny always": "始终拒绝",
    "Permission Required": "需要权限",
    "\u26a0 Permission Required": "\u26a0 需要权限",

    # ── File / Diff Views ──
    "Empty file": "空文件",
    "Markdown": "Markdown",
    "%lld lines": "%lld 行",
    "Image file (binary content not displayable)": "图片文件（二进制内容无法显示）",
    "Audio file (binary content not displayable)": "音频文件（二进制内容无法显示）",
    "Showing %lld of %lld lines": "显示 %2$lld 行中的 %1$lld 行",
    "Image preview unavailable": "图片预览不可用",
    "Open Full Screen": "全屏查看",
    "Copy": "复制",
    "Copy Old Text": "复制旧文本",
    "Copy as Diff": "复制为 Diff",
    "Save to Photos": "保存到相册",
    "Reader": "阅读模式",
    "Source": "源码",
    "Copied": "已复制",
    "Computing diff…": "正在计算差异…",
    "Loading diff…": "正在加载差异…",

    # ── Session Changes ──
    "Summary": "摘要",
    "Changed Files": "已更改文件",
    "Overall Diff": "总体差异",
    "Overview": "概览",
    "Revisions": "修订历史",
    "Change": "变更",
    "%lld changes": "%lld 个变更",
    "edit %lld": "编辑 %lld",
    "write %lld": "写入 %lld",
    "no net change": "无净变更",
    "Revision 1 \u2192 Revision %lld": "版本 1 → 版本 %lld",
    "Diff unavailable for this change.": "此变更的差异不可用。",
    "Write content unavailable for this change.": "此变更的写入内容不可用。",
    "Edit and write tool calls will appear here.": "编辑和写入工具调用将显示在此处。",
    "%lld items": "%lld 项",
    "Compaction": "压缩",
    "modified": "已修改",
    "Search session timeline…": "搜索会话时间线…",
    "Search changed files…": "搜索已更改文件…",
    "Change Detail": "变更详情",
    "Write Detail": "写入详情",
    "Diff": "差异",
    "Content": "内容",
    "%@ #%lld": "%1$@ #%2$lld",

    # ── Server Detail ──
    "Remove Paired Server": "移除已配对服务器",
    "Danger Zone": "危险区域",
    "This only removes pairing from this iPhone. It does not delete the server or its data.": "此操作仅从此 iPhone 移除配对，不会删除服务器或其数据。",
    "Preview": "预览",
    "Unable to reach server": "无法连接到服务器",

    # ── Session Row ──
    "%lld msgs": "%lld 条消息",
    "Terminal": "终端",
    "1 file touched": "1 个文件被修改",
    "%lld files touched": "%lld 个文件被修改",

    # ── Context Menus (UIKit — need String(localized:)) ──
    "Copy Output": "复制输出",
    "Copy Command": "复制命令",
    "View Full Screen": "全屏查看",
    "Copy Image": "复制图片",
    "Fork from here": "从此处分叉",
    "Copy as Markdown": "复制为 Markdown",
    "Thinking": "思考",
    "Terminal output": "终端输出",

    # ── System Events (TimelineReducer) ──
    "Context overflow \u2014 compacting...": "上下文溢出 \u2014 正在压缩…",
    "Compacting context...": "正在压缩上下文…",
    "Compaction cancelled": "压缩已取消",
    "Context compacted \u2014 retrying...": "上下文已压缩 \u2014 正在重试…",
    "Model changed": "模型已切换",
    "Thinking level changed": "思考级别已更改",

    # ── Notifications / Live Activity ──
    "Approval required": "需要审批",
    "Open Oppi to review": "打开 Oppi 查看",
    "%lld approvals": "%lld 个待审批",

    # ── Accessibility ──
    "Rename session": "重命名会话",
    "Cross-session permission request": "跨会话权限请求",
    "Local session environment": "本地会话环境",
    "Stop recording": "停止录制",
    "Start voice input": "开始语音输入",
    "%@ session status": "%@会话状态",
    "Server settings for %@": "%@ 的服务器设置",
    "Create workspace on %@": "在 %@ 上创建工作区",
    "View %@ details": "查看 %@ 详情",

    # ── Misc interpolated ──
    "[%@] Approval needed in %@": "[%1$@] %2$@ 中需要审批",
    "Approval needed in %@": "%@ 中需要审批",
    "Manual: %@": "手动: %@",
    "Extensions API: %@": "扩展 API: %@",
    "%lld changed": "%lld 个已更改",
    "... and %lld more": "… 及其他 %lld 个",
    "%lld stash": "%lld 个暂存",

    # ── Live Activity phase labels ──
    "Working": "运行中",
    "Your turn": "轮到你了",
    "Approval": "待审批",
    "Attention": "需要注意",
    "Attention needed": "需要注意",
    "Idle": "空闲",
    "Session ended": "会话已结束",
    "Run": "运行",
    "Reply": "回复",
    "Err": "错误",
    "%lld pending approvals": "%lld 个待审批",
    "Deny permission request": "拒绝权限请求",
    "Approve permission request": "批准权限请求",
    "Session timer": "会话计时器",

    # ── Strings that stay the same (brand/universal) ──
    "Oppi": None,
    "\u03c0": None,  # π logo
}

# ─── InfoPlist strings ───
info_plist: dict[str, dict[str, str]] = {
    "CFBundleDisplayName": {
        "en": "Oppi",
        "zh-Hans": "Oppi",
    },
    "NSCameraUsageDescription": {
        "en": "Oppi uses the camera to take photos for agent conversations.",
        "zh-Hans": "Oppi 使用相机为智能体对话拍摄照片。",
    },
    "NSPhotoLibraryAddUsageDescription": {
        "en": "Oppi saves images from agent conversations to your photo library.",
        "zh-Hans": "Oppi 将智能体对话中的图片保存到你的相册。",
    },
    "NSPhotoLibraryUsageDescription": {
        "en": "Oppi accesses your photo library to attach images to agent conversations.",
        "zh-Hans": "Oppi 访问你的相册以将图片附加到智能体对话中。",
    },
    "NSLocalNetworkUsageDescription": {
        "en": "Oppi needs local network access to connect to your Mac server.",
        "zh-Hans": "Oppi 需要本地网络访问权限以连接到你的 Mac 服务器。",
    },
    "NSMicrophoneUsageDescription": {
        "en": "Oppi uses the microphone to transcribe your voice into text prompts.",
        "zh-Hans": "Oppi 使用麦克风将你的语音转录为文本提示词。",
    },
    "NSSpeechRecognitionUsageDescription": {
        "en": "Oppi uses on-device speech recognition to convert your voice into text.",
        "zh-Hans": "Oppi 使用设备端语音识别将你的语音转换为文本。",
    },
    "NSFaceIDUsageDescription": {
        "en": "Oppi uses Face ID to confirm approval of high-risk agent actions like sudo, force push, and recursive deletes.",
        "zh-Hans": "Oppi 使用面容 ID 确认批准高风险智能体操作，例如 sudo、强制推送和递归删除。",
    },
}


def build_localizable(strings: dict[str, str | None]) -> dict:
    catalog: dict = {
        "sourceLanguage": "en",
        "version": "1.0",
        "strings": {},
    }
    for key, zh in sorted(strings.items()):
        entry: dict = {}
        if zh is not None:
            entry["localizations"] = {
                "zh-Hans": {
                    "stringUnit": {
                        "state": "translated",
                        "value": zh,
                    }
                }
            }
        catalog["strings"][key] = entry
    return catalog


def build_infoplist(info: dict[str, dict[str, str]]) -> dict:
    catalog: dict = {
        "sourceLanguage": "en",
        "version": "1.0",
        "strings": {},
    }
    for key, translations in sorted(info.items()):
        entry: dict = {"localizations": {}}
        for lang, value in sorted(translations.items()):
            entry["localizations"][lang] = {
                "stringUnit": {
                    "state": "translated",
                    "value": value,
                }
            }
        catalog["strings"][key] = entry
    return catalog


# ─── Activity Extension strings ───
extension_strings: dict[str, str | None] = {
    # Phase labels (from phaseLabel/phaseShortLabel — String returns, need String(localized:))
    "Working": "运行中",
    "Your turn": "轮到你了",
    "Approval": "待审批",
    "Attention": "需要注意",
    "Idle": "空闲",
    "Run": "运行",
    "Reply": "回复",
    "Ask": "询问",
    "Err": "错误",
    # SwiftUI auto-resolve (Label/Text literals)
    "Deny": "拒绝",
    "Approve": "批准",
    "Approval required": "需要审批",
    "%lld approvals": "%lld 个待审批",
    # Accessibility
    "Deny permission request": "拒绝权限请求",
    "Approve permission request": "批准权限请求",
    "%lld pending approvals": "%lld 个待审批",
    "Session timer": "会话计时器",
}


def main():
    ios_dir = Path(__file__).resolve().parent.parent

    loc_path = ios_dir / "Oppi" / "Resources" / "Localizable.xcstrings"
    loc_catalog = build_localizable(strings)
    loc_path.write_text(json.dumps(loc_catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"Wrote {loc_path} ({len(strings)} strings)")

    info_path = ios_dir / "Oppi" / "Resources" / "InfoPlist.xcstrings"
    info_catalog = build_infoplist(info_plist)
    info_path.write_text(json.dumps(info_catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"Wrote {info_path} ({len(info_plist)} strings)")

    ext_path = ios_dir / "OppiActivityExtension" / "Localizable.xcstrings"
    ext_catalog = build_localizable(extension_strings)
    ext_path.write_text(json.dumps(ext_catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"Wrote {ext_path} ({len(extension_strings)} strings)")


if __name__ == "__main__":
    main()
