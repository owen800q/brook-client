# Tiny HTTP server that replies with the caller's IP, so tests can see which path a request took.
import http.server
import sys


class Echo(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"{self.client_address[0]}\n".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Echo).serve_forever()
