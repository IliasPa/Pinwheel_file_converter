using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Pinwheel.Core;

namespace Pinwheel;

/// <summary>
/// Pictures, with Windows' own imaging (WIC): read any picture Windows can
/// open, turned the way the camera meant, and write PNG, JPEG, GIF, TIFF,
/// BMP, ICO and PDF. Runs on its own STA thread (see <see cref="Sta"/>).
/// </summary>
static class ImageWork
{
    /// <summary>A picture's first frame, upright, and how many frames it has (an animated GIF has several).</summary>
    public static (BitmapSource Picture, int Frames) Load(string path)
    {
        using var stream = File.OpenRead(path);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        if (decoder.Frames.Count == 0) throw new ConversionException("There's no picture in it.");
        BitmapSource frame = decoder.Frames[0];
        var upright = Upright(frame, Orientation(frame));
        upright.Freeze();
        return (upright, decoder.Frames.Count);
    }

    /// <summary>The EXIF orientation (1 to 8); 1 when there's none.</summary>
    static int Orientation(BitmapSource frame)
    {
        try
        {
            if (frame.Metadata is BitmapMetadata metadata && metadata.GetQuery("System.Photo.Orientation") is ushort value && value is >= 1 and <= 8)
                return value;
        }
        catch (Exception exception) when (exception is NotSupportedException or InvalidOperationException or ArgumentException)
        {
        }
        return 1;
    }

    /// <summary>Turns and flips a photo the way its camera says it was held.</summary>
    public static BitmapSource Upright(BitmapSource picture, int orientation)
    {
        Transform? transform = orientation switch
        {
            2 => new ScaleTransform(-1, 1),
            3 => new RotateTransform(180),
            4 => new ScaleTransform(1, -1),
            5 => Group(new RotateTransform(90), new ScaleTransform(-1, 1)),
            6 => new RotateTransform(90),
            7 => Group(new RotateTransform(90), new ScaleTransform(1, -1)),
            8 => new RotateTransform(270),
            _ => null,
        };
        return transform is null ? picture : new TransformedBitmap(picture, transform);

        static Transform Group(params Transform[] steps)
        {
            var group = new TransformGroup();
            foreach (var step in steps) group.Children.Add(step);
            return group;
        }
    }

    public static BitmapSource Bgra(BitmapSource picture) =>
        picture.Format == PixelFormats.Bgra32 ? picture : new FormatConvertedBitmap(picture, PixelFormats.Bgra32, null, 0);

    /// <summary>Pixel formats that can hold see-through pixels (palettes may have a see-through color).</summary>
    static readonly HashSet<PixelFormat> FormatsWithAlpha =
    [
        PixelFormats.Bgra32, PixelFormats.Pbgra32, PixelFormats.Rgba64, PixelFormats.Prgba64, PixelFormats.Rgba128Float,
        PixelFormats.Prgba128Float, PixelFormats.Indexed1, PixelFormats.Indexed2, PixelFormats.Indexed4, PixelFormats.Indexed8,
    ];

    /// <summary>Whether any pixel is see-through.</summary>
    public static bool HasTransparency(BitmapSource picture)
    {
        if (!FormatsWithAlpha.Contains(picture.Format)) return false;
        var bgra = Bgra(picture);
        var stride = bgra.PixelWidth * 4;
        var row = new byte[stride];
        for (var y = 0; y < bgra.PixelHeight; y++)
        {
            bgra.CopyPixels(new Int32Rect(0, y, bgra.PixelWidth, 1), row, stride, 0);
            for (var i = 3; i < stride; i += 4)
            {
                if (row[i] != 255) return true;
            }
        }
        return false;
    }

    /// <summary>See-through parts on a background (white), for formats without transparency.</summary>
    public static BitmapSource Flatten(BitmapSource picture, Color background)
    {
        var bgra = Bgra(picture);
        int width = bgra.PixelWidth, height = bgra.PixelHeight;
        var source = new byte[width * 4];
        var target = new byte[width * 3 * height];
        for (var y = 0; y < height; y++)
        {
            bgra.CopyPixels(new Int32Rect(0, y, width, 1), source, width * 4, 0);
            var t = y * width * 3;
            for (var x = 0; x < width; x++)
            {
                int s = x * 4, a = source[s + 3], rest = 255 - a;
                target[t++] = (byte)((source[s] * a + background.B * rest + 127) / 255);
                target[t++] = (byte)((source[s + 1] * a + background.G * rest + 127) / 255);
                target[t++] = (byte)((source[s + 2] * a + background.R * rest + 127) / 255);
            }
        }
        var flat = BitmapSource.Create(width, height, Dpi(picture.DpiX), Dpi(picture.DpiY), PixelFormats.Bgr24, null, target, width * 3);
        flat.Freeze();
        return flat;
    }

    static double Dpi(double dpi) => dpi is > 1 and < 10000 ? dpi : 96;

    /// <summary>Writes one picture as PNG, JPEG, GIF, TIFF, BMP or ICO.</summary>
    public static void Save(BitmapSource picture, OutputFormat format, string path, int jpegQuality)
    {
        byte[] bytes = format switch
        {
            OutputFormat.Png => Encode(new PngBitmapEncoder(), Bgra(picture)),
            OutputFormat.Tiff => Encode(new TiffBitmapEncoder { Compression = TiffCompressOption.Lzw }, Bgra(picture)),
            OutputFormat.Jpeg => Jpeg(picture, jpegQuality),
            OutputFormat.Bmp => Encode(new BmpBitmapEncoder(), Flatten(picture, Colors.White)),
            OutputFormat.Gif => Gif(picture),
            OutputFormat.Ico => Icon(picture),
            _ => throw new ArgumentException($"{format.Title()} isn't a picture Windows writes.", nameof(format)),
        };
        WriteNew(path, bytes);
    }

    public static byte[] Jpeg(BitmapSource picture, int quality) =>
        Encode(new JpegBitmapEncoder { QualityLevel = Math.Clamp(quality, 1, 100) }, Flatten(picture, Colors.White));

    /// <summary>
    /// A GIF in the 256 colors that suit this picture best. See-through parts
    /// stay see-through (one of the colors is kept for them).
    /// </summary>
    static byte[] Gif(BitmapSource picture)
    {
        var bgra = Bgra(picture);
        var transparent = HasTransparency(bgra);
        var flat = Flatten(bgra, Colors.White);
        if (!transparent)
            return Encode(new GifBitmapEncoder(), new FormatConvertedBitmap(flat, PixelFormats.Indexed8, new BitmapPalette(flat, 256), 0));

        // Windows' color reduction ignores see-through pixels, so: 255 colors
        // for the picture, and the last palette entry for what's see-through.
        var colors = new BitmapPalette(flat, 255).Colors.ToList();
        var indexed = new FormatConvertedBitmap(flat, PixelFormats.Indexed8, new BitmapPalette(colors), 0);
        int width = bgra.PixelWidth, height = bgra.PixelHeight;
        var indices = new byte[width * height];
        indexed.CopyPixels(indices, width, 0);
        var clear = (byte)colors.Count;
        var row = new byte[width * 4];
        for (var y = 0; y < height; y++)
        {
            bgra.CopyPixels(new Int32Rect(0, y, width, 1), row, width * 4, 0);
            for (var x = 0; x < width; x++)
            {
                if (row[x * 4 + 3] < 128) indices[y * width + x] = clear;
            }
        }
        colors.Add(Color.FromArgb(0, 255, 255, 255));
        var frame = BitmapSource.Create(width, height, Dpi(picture.DpiX), Dpi(picture.DpiY), PixelFormats.Indexed8, new BitmapPalette(colors), indices, width);
        var encoder = new GifBitmapEncoder();
        BitmapMetadata? metadata = null;
        try
        {
            // The GIF's own word for "this color is see-through".
            metadata = new BitmapMetadata("gif");
            metadata.SetQuery("/grctlext/TransparencyFlag", true);
            metadata.SetQuery("/grctlext/TransparentColorIndex", clear);
        }
        catch (Exception exception) when (exception is NotSupportedException or InvalidOperationException or ArgumentException
                                          or System.Runtime.InteropServices.COMException)
        {
            metadata = null;
        }
        encoder.Frames.Add(BitmapFrame.Create(frame, null, metadata, null));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    /// <summary>An icon with every size up to 256 (or the picture's own size), each a square PNG.</summary>
    static byte[] Icon(BitmapSource picture)
    {
        var largest = Math.Max(picture.PixelWidth, picture.PixelHeight);
        var sizes = IcoWriter.Sizes.Where(size => size <= Math.Max(largest, 16)).ToList();
        var images = sizes.Select(size => (Encode(new PngBitmapEncoder(), Square(picture, size)), size)).ToList();
        return IcoWriter.Write(images);
    }

    /// <summary>The picture fitted into a square, centered, with see-through room around it.</summary>
    public static BitmapSource Square(BitmapSource picture, int size)
    {
        var scale = Math.Min((double)size / picture.PixelWidth, (double)size / picture.PixelHeight);
        double width = picture.PixelWidth * scale, height = picture.PixelHeight * scale;
        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
        using (var context = visual.RenderOpen())
        {
            context.DrawImage(picture, new Rect((size - width) / 2, (size - height) / 2, width, height));
        }
        var target = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        target.Render(visual);
        target.Freeze();
        return target;
    }

    /// <summary>All the pictures in one PDF, a page each, as JPEGs.</summary>
    public static void SavePdf(IReadOnlyList<BitmapSource> pictures, string path, int jpegQuality)
    {
        var pages = pictures.Select(picture => new PdfWriter.Page(
            Jpeg(picture, Math.Max(jpegQuality, 90)), picture.PixelWidth, picture.PixelHeight, Dpi(picture.DpiX))).ToList();
        WriteNew(path, PdfWriter.Write(pages));
    }

    public static byte[] Encode(BitmapEncoder encoder, BitmapSource picture)
    {
        encoder.Frames.Add(BitmapFrame.Create(picture));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    /// <summary>Writes a new file; never replaces one that's there.</summary>
    public static void WriteNew(string path, byte[] bytes)
    {
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
        file.Write(bytes, 0, bytes.Length);
    }
}

/// <summary>A conversion that couldn't be done, with a reason people can read.</summary>
sealed class ConversionException(string message) : Exception(message);
