using System.Globalization;
using System.Text;

namespace Pinwheel.Core;

/// <summary>Writes a Windows icon (.ico) from PNG pictures, one per size.</summary>
public static class IcoWriter
{
    /// <summary>The sizes a Windows icon has, small to large.</summary>
    public static readonly int[] Sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];

    /// <summary>Each entry: a square PNG and its size in pixels (at most 256).</summary>
    public static byte[] Write(IReadOnlyList<(byte[] Png, int Size)> images)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write((ushort)0);  // reserved
        writer.Write((ushort)1);  // an icon (2 would be a cursor)
        writer.Write((ushort)images.Count);
        var offset = 6 + 16 * images.Count;
        foreach (var (png, size) in images)
        {
            writer.Write((byte)(size >= 256 ? 0 : size));  // 0 means 256
            writer.Write((byte)(size >= 256 ? 0 : size));
            writer.Write((byte)0);   // no palette
            writer.Write((byte)0);   // reserved
            writer.Write((ushort)1); // planes
            writer.Write((ushort)32);
            writer.Write((uint)png.Length);
            writer.Write((uint)offset);
            offset += png.Length;
        }
        foreach (var (png, _) in images) writer.Write(png);
        writer.Flush();
        return stream.ToArray();
    }
}

/// <summary>Writes a PDF with a picture on each page, from JPEG data.</summary>
public static class PdfWriter
{
    /// <summary>One page: a JPEG, its size in pixels and how many pixels make an inch.</summary>
    public sealed record Page(byte[] Jpeg, int PixelWidth, int PixelHeight, double Dpi = 72, bool Gray = false);

    public static byte[] Write(IReadOnlyList<Page> pages)
    {
        if (pages.Count == 0) throw new ArgumentException("A PDF needs a page.", nameof(pages));
        using var stream = new MemoryStream();
        var offsets = new List<long>();
        void Text(string s)
        {
            var bytes = Encoding.ASCII.GetBytes(s);
            stream.Write(bytes, 0, bytes.Length);
        }
        void Begin(int number)
        {
            while (offsets.Count < number) offsets.Add(0);
            offsets[number - 1] = stream.Position;
            Text($"{number} 0 obj\n");
        }
        static string N(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);

        Text("%PDF-1.4\n");
        stream.Write([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);  // says "binary inside" to tools that guess
        // 1: catalog, 2: pages; then three objects per page: page, picture, drawing.
        Begin(1);
        Text("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        Begin(2);
        var kids = string.Join(" ", Enumerable.Range(0, pages.Count).Select(i => $"{3 + i * 3} 0 R"));
        Text($"<< /Type /Pages /Kids [{kids}] /Count {pages.Count} >>\nendobj\n");
        for (var i = 0; i < pages.Count; i++)
        {
            var page = pages[i];
            int pageNumber = 3 + i * 3, imageNumber = pageNumber + 1, contentNumber = pageNumber + 2;
            // A pixel is 1/dpi of an inch; a PDF point is 1/72.
            var dpi = page.Dpi >= 1 ? page.Dpi : 72;
            double width = page.PixelWidth * 72 / dpi, height = page.PixelHeight * 72 / dpi;
            Begin(pageNumber);
            Text($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {N(width)} {N(height)}] " +
                 $"/Resources << /XObject << /Im0 {imageNumber} 0 R >> >> /Contents {contentNumber} 0 R >>\nendobj\n");
            Begin(imageNumber);
            Text($"<< /Type /XObject /Subtype /Image /Width {page.PixelWidth} /Height {page.PixelHeight} " +
                 $"/ColorSpace /{(page.Gray ? "DeviceGray" : "DeviceRGB")} /BitsPerComponent 8 /Filter /DCTDecode /Length {page.Jpeg.Length} >>\nstream\n");
            stream.Write(page.Jpeg, 0, page.Jpeg.Length);
            Text("\nendstream\nendobj\n");
            var drawing = $"q {N(width)} 0 0 {N(height)} 0 0 cm /Im0 Do Q";
            Begin(contentNumber);
            Text($"<< /Length {drawing.Length} >>\nstream\n{drawing}\nendstream\nendobj\n");
        }
        var xref = stream.Position;
        Text($"xref\n0 {offsets.Count + 1}\n0000000000 65535 f\r\n");
        foreach (var offset in offsets) Text($"{offset:D10} 00000 n\r\n");
        Text($"trailer\n<< /Size {offsets.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return stream.ToArray();
    }
}
