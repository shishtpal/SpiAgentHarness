using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace SpiAgentHarness
{
    // Async IO runs without a PowerShell runspace; bound each line before allocating it.
    public sealed class McpLineReader : IDisposable
    {
        private readonly StreamReader reader;
        private readonly int limit;
        private readonly char[] buffer = new char[4096];
        private int position;
        private int count;

        public McpLineReader(StreamReader reader, int limit)
        {
            this.reader = reader;
            this.limit = limit;
        }

        public async Task<string> ReadLineAsync()
        {
            var line = new StringBuilder();
            while (true)
            {
                if (position == count)
                {
                    count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    position = 0;
                    if (count == 0)
                        return line.Length == 0 ? null : line.ToString().TrimEnd('\r');
                }
                int end = position;
                while (end < count && buffer[end] != '\n') end++;
                if (line.Length + end - position > limit)
                    throw new InvalidDataException("MCP response line exceeded MaxResponseChars.");
                line.Append(buffer, position, end - position);
                position = end;
                if (position < count && buffer[position] == '\n')
                {
                    position++;
                    return line.ToString().TrimEnd('\r');
                }
            }
        }

        public void Dispose() { reader.Dispose(); }
    }
}