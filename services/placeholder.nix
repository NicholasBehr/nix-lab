{pkgs, ...}: {
  services.nginx.virtualHosts."vpn.nicholasbehr.ch" = {
    root = pkgs.writeTextDir "index.html" ''
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>vpn.nicholasbehr.ch</title>
        </head>
        <body>
          <main>
            <h1>vpn.nicholasbehr.ch</h1>
            <p>nginx is running.</p>
          </main>
        </body>
      </html>
    '';
    enableACME = true;
    forceSSL = true;
  };
}
