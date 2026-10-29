import AppKit

// 使用新生成的虚构截图排版展示板，不读取旧设计图或用户资料。
let width: CGFloat = 1320, height: CGFloat = 2060
let board = NSImage(size: NSSize(width: width, height: height))
board.lockFocus()
NSColor(calibratedRed: 0.97, green: 0.975, blue: 0.985, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
func drawText(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, color: NSColor = .labelColor) {
    (value as NSString).draw(in: NSRect(x: x, y: height - top - 56, width: width - x - 32, height: 56), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
}
drawText("轻松记账 · 界面与备份流程示例", x: 42, top: 25, size: 34)
drawText("所有账户、金额、账本和备注均为独立虚构资料，仅用于演示。", x: 42, top: 83, size: 20, color: .secondaryLabelColor)
let pages = [("home", "01 首页"), ("entry", "02 记一笔"), ("reports", "03 报表"), ("assets", "04 资产"), ("books", "05 账本"), ("data", "06 数据管理")]
for (index, page) in pages.enumerated() {
    let x = CGFloat(index % 3) * 428 + 32
    let top = CGFloat(index / 3) * 900 + 155
    let card = NSRect(x: x, y: height - top - 865, width: 400, height: 865)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22).fill()
    drawText(page.1, x: x + 20, top: top + 12, size: 23)
    guard let image = NSImage(contentsOfFile: "screenshots/\(page.0).png") else { fatalError("缺少虚构截图：\(page.0)") }
    let imageHeight: CGFloat = 775
    let imageWidth = image.size.width / image.size.height * imageHeight
    let rect = NSRect(x: x + (400 - imageWidth) / 2, y: height - top - 70 - imageHeight, width: imageWidth, height: imageHeight)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).addClip()
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}
drawText("演示预览使用内存数据库；正式首次安装为零余额账户与空白账本。", x: 42, top: 1980, size: 20, color: .secondaryLabelColor)
board.unlockFocus()
guard let tiff = board.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("无法生成界面展示板") }
try data.write(to: URL(fileURLWithPath: "screenshots/ui-demo-board.png"))
print("设计图:" + data.base64EncodedString() + ":设计图结束")
