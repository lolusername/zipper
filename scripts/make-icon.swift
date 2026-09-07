import AppKit
import Foundation
let resources=CommandLine.arguments[1]
let iconset=URL(fileURLWithPath:resources).appendingPathComponent("Zipper.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let image=NSImage(size:NSSize(width:pixels,height:pixels))
        image.lockFocus()
        let context=NSGraphicsContext.current!.cgContext
        context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
        NSColor(calibratedRed:0.07,green:0.09,blue:0.11,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:62,y:62,width:900,height:900),xRadius:190,yRadius:190).fill()
        NSColor(calibratedRed:0.18,green:0.25,blue:0.28,alpha:1).setStroke()
        let border=NSBezierPath(roundedRect:NSRect(x:65,y:65,width:894,height:894),xRadius:190,yRadius:190);border.lineWidth=5;border.stroke()
        NSColor(calibratedRed:0.40,green:0.88,blue:0.77,alpha:1).setFill()
        let z=NSBezierPath();z.move(to:NSPoint(x:270,y:732));z.line(to:NSPoint(x:753,y:732));z.line(to:NSPoint(x:753,y:642));z.line(to:NSPoint(x:413,y:359));z.line(to:NSPoint(x:753,y:359));z.line(to:NSPoint(x:753,y:270));z.line(to:NSPoint(x:270,y:270));z.line(to:NSPoint(x:270,y:361));z.line(to:NSPoint(x:609,y:641));z.line(to:NSPoint(x:270,y:641));z.close();z.fill()
        NSColor(calibratedRed:0.07,green:0.09,blue:0.11,alpha:1).setStroke()
        for y in stride(from:410,through:590,by:45) {let line=NSBezierPath();line.move(to:NSPoint(x:455,y:y));line.line(to:NSPoint(x:565,y:y));line.lineWidth=14;line.stroke()}
        image.unlockFocus()
        let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
        let name="icon_\(size)x\(size)\(scale==2 ? "@2x" : "").png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:iconset.appendingPathComponent(name))
    }
}
let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/iconutil");process.arguments=["-c","icns",iconset.path,"-o",URL(fileURLWithPath:resources).appendingPathComponent("Zipper.icns").path]
try process.run();process.waitUntilExit();guard process.terminationStatus==0 else{exit(1)}
try FileManager.default.removeItem(at:iconset)
