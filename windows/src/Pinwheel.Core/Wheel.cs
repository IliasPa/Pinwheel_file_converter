namespace Pinwheel.Core;

public enum HitArea { Hub, Wedge, Outside }

/// <summary>Where a point is on the wheel; <see cref="Index"/> is the wedge's.</summary>
public readonly record struct WheelHit(HitArea Area, int Index = -1);

/// <summary>
/// The wheel's shape: a hub in the middle and <see cref="Count"/> wedges
/// around it, the first at 12 o'clock. Angles are in radians, clockwise
/// from the top; points are in screen coordinates (y down).
/// </summary>
public readonly record struct WheelLayout(int Count, double InnerRadius, double OuterRadius, double OuterSlack = 16)
{
    public double Step => Count > 0 ? 2 * Math.PI / Count : 2 * Math.PI;

    public double CenterAngle(int index) => index * Step;
    public double StartAngle(int index) => CenterAngle(index) - Step / 2;
    public double EndAngle(int index) => CenterAngle(index) + Step / 2;

    /// <summary><paramref name="dx"/>, <paramref name="dy"/>: from the center, y down.</summary>
    public WheelHit Hit(double dx, double dy)
    {
        var r = Math.Sqrt(dx * dx + dy * dy);
        if (r < InnerRadius) return new WheelHit(HitArea.Hub);
        // A drop just past the rim still counts.
        if (r > OuterRadius + OuterSlack || Count == 0) return new WheelHit(HitArea.Outside);
        var angle = Math.Atan2(dx, -dy);
        if (angle < 0) angle += 2 * Math.PI;
        var shifted = (angle + Step / 2) % (2 * Math.PI);
        return new WheelHit(HitArea.Wedge, Math.Min((int)(shifted / Step), Count - 1));
    }

    /// <summary>A point at <paramref name="radius"/> along <paramref name="angle"/>.</summary>
    public static (double X, double Y) PointAt(double cx, double cy, double radius, double angle) =>
        (cx + radius * Math.Sin(angle), cy - radius * Math.Cos(angle));

    /// <summary>
    /// Moves the wheel's center just enough that a circle of
    /// <paramref name="radius"/> stays inside the screen's area.
    /// </summary>
    public static (double X, double Y) ClampedCenter(double x, double y, double radius, double left, double top, double right, double bottom)
    {
        static double Clamp(double v, double lo, double hi) => lo > hi ? (lo + hi) / 2 : Math.Min(Math.Max(v, lo), hi);
        return (Clamp(x, left + radius, right - radius), Clamp(y, top + radius, bottom - radius));
    }
}

/// <summary>
/// One wedge's outline: an arc of the ring with an even gap to its
/// neighbours. The outline is shrunk by the corner radius; drawing it with a
/// round-joined stroke twice that wide brings it back with rounded corners.
/// </summary>
public static class WedgeOutline
{
    public static IReadOnlyList<(double X, double Y)> Points(
        double cx, double cy, double innerRadius, double outerRadius,
        double startAngle, double endAngle, double gap, double cornerRadius)
    {
        var corner = Math.Max(0, Math.Min(cornerRadius, (outerRadius - innerRadius) / 2 - 0.5));
        var edgeOffset = gap / 2 + corner;
        var rIn = innerRadius + corner;
        var rOut = outerRadius - corner;
        if (rIn <= edgeOffset || rOut <= rIn) return [];

        var outStart = startAngle + Math.Asin(edgeOffset / rOut);
        var outEnd = endAngle - Math.Asin(edgeOffset / rOut);
        var inStart = startAngle + Math.Asin(edgeOffset / rIn);
        var inEnd = endAngle - Math.Asin(edgeOffset / rIn);
        if (outEnd <= outStart || inEnd <= inStart) return [];

        static int Steps(double from, double to) => Math.Max(2, (int)(Math.Abs(to - from) / (Math.PI / 90)));  // a point every 2°

        var points = new List<(double X, double Y)> { WheelLayout.PointAt(cx, cy, rOut, outStart) };
        var outerSteps = Steps(outStart, outEnd);
        for (var i = 1; i <= outerSteps; i++)
            points.Add(WheelLayout.PointAt(cx, cy, rOut, outStart + (outEnd - outStart) * i / outerSteps));
        points.Add(WheelLayout.PointAt(cx, cy, rIn, inEnd));
        var innerSteps = Steps(inStart, inEnd);
        for (var i = 1; i <= innerSteps; i++)
            points.Add(WheelLayout.PointAt(cx, cy, rIn, inEnd - (inEnd - inStart) * i / innerSteps));
        return points;
    }

    /// <summary>The stroke width that rounds the corners back.</summary>
    public static double StrokeWidth(double innerRadius, double outerRadius, double cornerRadius) =>
        2 * Math.Max(0, Math.Min(cornerRadius, (outerRadius - innerRadius) / 2 - 0.5));
}
