using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace SpiAgentHarness
{
    public sealed class ShellSnapshot
    {
        public string Id { get; set; }
        public string State { get; set; }
        public int? ExitCode { get; set; }
        public string Output { get; set; }
        public string Error { get; set; }
        public long OutputChars { get; set; }
        public long ErrorChars { get; set; }
        public bool CaptureIncomplete { get; set; }
        public string TerminationError { get; set; }
    }

    // No PowerShell callbacks run on worker threads. Both pipes are drained even
    // after their retained tails fill, and deadlines do not depend on polling.
    public sealed class ShellProcess : IDisposable
    {
        private readonly object gate = new object();
        private readonly Process process;
        private readonly StringBuilder output = new StringBuilder();
        private readonly StringBuilder error = new StringBuilder();
        private readonly Task outputReader;
        private readonly Task errorReader;
        private readonly Task inputWriter;
        private readonly Task completion;
        private readonly Timer deadline;
        private long outputChars;
        private long errorChars;
        private string stopReason;
        private string terminationError;
        private int? exitCode;
        private bool completed;
        private bool captureIncomplete;
        private bool disposed;
        private const int RetainedChars = 65536;

        public string Id { get; private set; }
        public int TimeoutSec { get; private set; }
        public bool Completed { get { lock (gate) { return completed; } } }

        public ShellProcess(string executable, string command, string directory, int timeoutSec)
            : this(executable, new[] { "-NoProfile", "-NonInteractive", "-Command", command }, directory, timeoutSec, null, false)
        {
        }

        public ShellProcess(string executable, string[] arguments, string directory, int timeoutSec, string input, bool utf8)
        {
            Id = Guid.NewGuid().ToString("N");
            TimeoutSec = timeoutSec;
            var start = new ProcessStartInfo(executable);
            foreach (var argument in arguments)
                start.ArgumentList.Add(argument);
            start.WorkingDirectory = directory;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            if (utf8)
            {
                start.StandardOutputEncoding = new UTF8Encoding(false);
                start.StandardErrorEncoding = new UTF8Encoding(false);
            }
            process = Process.Start(start);
            try
            {
                outputReader = Task.Run(() => Drain(process.StandardOutput, false));
                errorReader = Task.Run(() => Drain(process.StandardError, true));
                if (input == null)
                {
                    process.StandardInput.Close();
                    inputWriter = Task.CompletedTask;
                }
                else
                {
                    // Feed code without shell quoting or command-line size limits.
                    // Writing concurrently also keeps large input from blocking deadlines.
                    inputWriter = Task.Run(async () =>
                    {
                        try
                        {
                            var bytes = new UTF8Encoding(false).GetBytes(input);
                            await process.StandardInput.BaseStream.WriteAsync(bytes, 0, bytes.Length).ConfigureAwait(false);
                        }
                        catch { lock (gate) { captureIncomplete = true; } }
                        finally { try { process.StandardInput.Close(); } catch { } }
                    });
                }
                // Assign the timer before launching a potentially fast monitor.
                deadline = new Timer(_ => RequestStop("timed_out"), null, Timeout.Infinite, Timeout.Infinite);
                deadline.Change(TimeSpan.FromSeconds(timeoutSec), TimeSpan.FromSeconds(1));
                completion = Task.Factory.StartNew(Monitor, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            }
            catch
            {
                try { if (!process.HasExited) process.Kill(true); } catch { }
                process.Dispose();
                if (deadline != null) deadline.Dispose();
                throw;
            }
        }

        private async Task Drain(StreamReader reader, bool isError)
        {
            var buffer = new char[4096];
            try
            {
                int count;
                while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) != 0)
                {
                    lock (gate)
                    {
                        var tail = isError ? error : output;
                        if (isError) errorChars += count; else outputChars += count;
                        tail.Append(buffer, 0, count);
                        if (tail.Length > RetainedChars) tail.Remove(0, tail.Length - RetainedChars);
                    }
                }
            }
            catch { lock (gate) { captureIncomplete = true; } }
        }

        private void Monitor()
        {
            try
            {
                process.WaitForExit();
                lock (gate) { exitCode = process.ExitCode; }
                deadline.Change(Timeout.Infinite, Timeout.Infinite);
                // Descendants can hold inherited pipes after the parent exits.
                if (!Task.WaitAll(new[] { outputReader, errorReader, inputWriter }, 1000))
                {
                    lock (gate) { captureIncomplete = true; }
                    process.StandardOutput.Close();
                    process.StandardError.Close();
                    process.StandardInput.Close();
                }
            }
            catch { lock (gate) { captureIncomplete = true; } }
            finally
            {
                deadline.Dispose();
                lock (gate) { completed = true; }
            }
        }

        private void RequestStop(string reason)
        {
            lock (gate)
            {
                if (disposed || completed) return;
                try
                {
                    if (process.HasExited) return;
                    if (stopReason == null) stopReason = reason;
                    process.Kill(true);
                    terminationError = null;
                }
                catch (InvalidOperationException)
                {
                    // Natural exit can race cancellation.
                    try { if (!process.HasExited) terminationError = "Unable to terminate process tree."; }
                    catch { terminationError = "Unable to inspect process termination."; }
                }
                catch { terminationError = "Unable to terminate process tree."; }
            }
        }

        public void Stop() { RequestStop("cancelled"); }
        public bool Wait(int milliseconds) { return completion.Wait(milliseconds); }

        public ShellSnapshot Snapshot()
        {
            lock (gate)
            {
                return new ShellSnapshot {
                    Id = Id, State = completed ? (stopReason ?? "exited") : (stopReason == null ? "running" : "stopping"),
                    ExitCode = exitCode, Output = output.ToString(), Error = error.ToString(),
                    OutputChars = outputChars, ErrorChars = errorChars,
                    CaptureIncomplete = captureIncomplete, TerminationError = terminationError
                };
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            Stop();
            if (!completion.Wait(5000))
                throw new IOException("Shell process did not stop; cleanup could not be confirmed.");
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
                deadline.Dispose();
                process.Dispose();
            }
        }
    }
}