## rss-firehose

Aggregate Local RSS feeds into a lightweight page similar to https://lite.cnn.io

### Running:

To render the page:

```
ruby render.rb
```

Outputs `public/index.html`

To serve it with a simple sinatra server, run:

```
ruby server.rb
```

Browse to http://localhost:4567/ to view

### Docker

Served up on port 8080 with nginx:

```
docker run --rm -v rss-firehose:/usr/src/app/public -it rss-firehose
docker run --name rss-nginx --rm -v rss-firehose:/usr/share/nginx/html:ro -p 8080:80 nginx:1.14.0-alpine
```

Re-run the `rss-firehose` container to update the page.
