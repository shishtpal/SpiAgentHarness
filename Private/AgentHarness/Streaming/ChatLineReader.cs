using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace SpiAgentHarness
{
    // Bound lines before allocating them; preserve SSE's CR, LF and CRLF boundaries.
    public sealed class ChatLineReader : IDisposable
    {
        private readonly StreamReader reader;
        private readonly int limit;
        private readonly char[] buffer = new char[4096];
        private int position;
        private int count;
        private bool skipLf;
        private int total;

        public ChatLineReader(StreamReader reader, int limit)
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
                    if (count == 0) return line.Length == 0 ? null : line.ToString();
                }
                char value = buffer[position++];
                if (++total > limit) throw new InvalidDataException("Chat response exceeded the size limit.");
                if (skipLf)
                {
                    skipLf = false;
                    if (value == '\n') continue;
                }
                if (value == '\r') { skipLf = true; return line.ToString(); }
                if (value == '\n') return line.ToString();
                line.Append(value);
            }
        }

        public void Dispose() { reader.Dispose(); }
    }
}