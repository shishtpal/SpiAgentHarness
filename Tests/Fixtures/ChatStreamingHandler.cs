using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace SpiAgentHarness.Tests
{
    public sealed class ChatResponse
    {
        public string Body = "";
        public string MediaType = "text/event-stream";
        public int Status = 200;
        public int ReadSize = 1;
        public bool FaultAtEnd;
        public bool StallAtEnd;
        public int GateAt;
    }

    public sealed class ChatStream : MemoryStream
    {
        private readonly ChatResponse response;
        private readonly TaskCompletionSource<int> pending = new TaskCompletionSource<int>();
        public bool Released;
        public bool Disposed;

        public ChatStream(ChatResponse response) : base(Encoding.UTF8.GetBytes(response.Body)) { this.response = response; }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            if (response.GateAt > 0 && Position >= response.GateAt && !Released)
                return Task.FromException<int>(new IOException("Next fragment was read before the text callback."));
            if (Position == Length && response.FaultAtEnd)
                return Task.FromException<int>(new IOException("Synthetic disconnect."));
            if (Position == Length && response.StallAtEnd) return pending.Task;
            int size = Math.Min(count, response.ReadSize);
            if (response.GateAt > Position) size = Math.Min(size, response.GateAt - (int)Position);
            return Task.FromResult(base.Read(buffer, offset, size));
        }

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            return ReadMemoryAsync(buffer, cancellationToken);
        }

        private async ValueTask<int> ReadMemoryAsync(Memory<byte> buffer, CancellationToken cancellationToken)
        {
            var temporary = new byte[buffer.Length];
            int count = await ReadAsync(temporary, 0, temporary.Length, cancellationToken).ConfigureAwait(false);
            temporary.AsMemory(0, count).CopyTo(buffer);
            return count;
        }

        protected override void Dispose(bool disposing)
        {
            Disposed = true;
            pending.TrySetResult(0);
            base.Dispose(disposing);
        }
    }

    public sealed class ChatHandler : HttpMessageHandler
    {
        public readonly Queue<ChatResponse> Responses = new Queue<ChatResponse>();
        public readonly List<string> Bodies = new List<string>();
        public readonly List<string> Uris = new List<string>();
        public readonly List<Dictionary<string, string>> Headers = new List<Dictionary<string, string>>();
        public readonly List<ChatStream> Streams = new List<ChatStream>();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.RequestUri.Host != "provider.invalid") throw new InvalidOperationException("Unmocked endpoint.");
            if (Responses.Count == 0) throw new InvalidOperationException("No synthetic HTTP response remains.");
            Bodies.Add(await request.Content.ReadAsStringAsync().ConfigureAwait(false));
            Uris.Add(request.RequestUri.ToString());
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var pair in request.Headers) headers[pair.Key] = string.Join(",", pair.Value);
            Headers.Add(headers);
            var response = Responses.Dequeue();
            var stream = new ChatStream(response);
            Streams.Add(stream);
            var result = new HttpResponseMessage((HttpStatusCode)response.Status) { Content = new StreamContent(stream) };
            result.Content.Headers.ContentType = new MediaTypeHeaderValue(response.MediaType);
            return result;
        }
    }
}