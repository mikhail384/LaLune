import AppKit
import CoreImage
let img=CIImage(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))!
let out=img.clampedToExtent().applyingGaussianBlur(sigma:28).cropped(to:img.extent)
let context=CIContext(options:[.useSoftwareRenderer:true]);let cg=context.createCGImage(out,from:out.extent)!;let rep=NSBitmapImageRep(cgImage:cg);try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
