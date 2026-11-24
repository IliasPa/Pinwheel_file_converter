using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Pinwheel;

/// <summary>
/// One Pinwheel at a time. Started again (from Send to, say), it hands the
/// files to the one already running and quits.
/// </summary>
sealed class SingleInstance : IDisposable
{
    static readonly string Name = "Pinwheel-" + Environment.UserName;
    readonly Mutex mutex;
    readonly CancellationTokenSource stop = new();

    SingleInstance(Mutex mutex) => this.mutex = mutex;

    /// <summary>Files handed over by another start (raised on a background thread).</summary>
    public event Action<string[]>? FilesReceived;

    /// <summary>The running Pinwheel, or null when one was already running (the files went to it).</summary>
    public static SingleInstance? Claim(string[] files)
    {
        var mutex = new Mutex(initiallyOwned: true, @"Local\" + Name, out var createdNew);
        if (createdNew) return new SingleInstance(mutex);
        mutex.Dispose();
        HandOver(files);
        return null;
    }

    static void HandOver(string[] files)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", Name, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(3000);
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(files));
            pipe.Write(bytes, 0, bytes.Length);
        }
        catch (Exception exception) when (exception is IOException or TimeoutException or UnauthorizedAccessException)
        {
        }
    }

    public void Listen()
    {
        Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    using var pipe = new NamedPipeServerStream(Name, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await pipe.WaitForConnectionAsync(stop.Token);
                    using var reader = new StreamReader(pipe, Encoding.UTF8);
                    var text = await reader.ReadToEndAsync(stop.Token);
                    var files = JsonSerializer.Deserialize<string[]>(text);
                    if (files is { Length: > 0 }) FilesReceived?.Invoke(files);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception exception) when (exception is IOException or JsonException)
                {
                }
            }
        });
    }

    public void Dispose()
    {
        stop.Cancel();
        try
        {
            mutex.ReleaseMutex();
        }
        catch (ApplicationException)
        {
        }
        mutex.Dispose();
    }
}
