# RSS Firehose

RSS Firehose is a Ruby application that aggregates RSS feeds into a lightweight, responsive HTML page. It supports AI-powered summaries, backup feeds, error handling for offline sources, and Docker containerization.

**ALWAYS reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.**

## Working Effectively

### Bootstrap and Dependencies
- Install Ruby gems manually (bundler has permission issues in sandboxed environments):
  ```bash
  gem install --user-install httparty rss minitest
  export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
  ```
- Dependencies take ~30 seconds to install
- Required gems: `httparty` (HTTP requests), `rss` (RSS parsing), `minitest` (testing)

### Build and Render
- **NEVER CANCEL**: Render takes ~3 seconds. ALWAYS wait for completion.
- Main render command:
  ```bash
  ruby render.rb
  ```
- Outputs to: `public/index.html` and `public/manifest.json`
- The render script gracefully handles network failures and offline RSS feeds

### Testing
- **NEVER CANCEL**: Test suite takes ~3 seconds. ALWAYS wait for completion.
- Run tests:
  ```bash
  ruby test/render_test.rb
  ```
- Test suite includes 4 tests validating rendering, error handling, and backup feed functionality
- ALL tests should pass (4 runs, 8 assertions, 0 failures)

### Docker
- **NEVER CANCEL**: Docker build takes 2+ minutes when network is available. Set timeout to 5+ minutes.
- Build container:
  ```bash
  docker build -t djdefi/rss-firehose .
  ```
- Run container:
  ```bash
  docker run --rm -v rss-firehose:/usr/src/app/public -it djdefi/rss-firehose
  ```
- Note: Docker build may fail in network-restricted environments due to Alpine package installation

## Validation

### Manual Validation Requirements
After making changes, ALWAYS perform these validation steps:

1. **Render Validation**:
   ```bash
   ruby render.rb
   ```
   - Verify `public/index.html` is generated
   - Check file contains expected HTML structure with `<title>News Firehose</title>`
   - Verify graceful error handling for offline feeds (shows "Feed offline" messages)

2. **Test Validation**:
   ```bash
   ruby test/render_test.rb
   ```
   - ALL 4 tests must pass (4 runs, 8 assertions, 0 failures)
   - Validates HTML structure, error handling, and backup feed functionality

3. **Environment Variable Testing**:
   ```bash
   RSS_TITLE="Test Title" RSS_DESCRIPTION="Test Description" ruby render.rb
   ```
   - Verify custom title/description appears in generated HTML

4. **Live Preview Validation**:
   ```bash
   cd public && python3 -m http.server 8000
   ```
   - Visit http://localhost:8000 to view generated page
   - Verify responsive design and accessibility features work
   - Check that offline feeds show "Feed offline" placeholder messages

5. **Code Quality** (when available):
   ```bash
   bundle exec rubocop --require code_scanning --format CodeScanning::SarifFormatter -o rubocop.sarif
   ```

### Functional Scenarios to Test
- **Basic rendering**: Verify HTML generation with default feeds
- **Error handling**: Test with invalid/offline RSS URLs (should show "Feed offline" placeholders)
- **Backup feeds**: Test fallback when primary feeds are empty/invalid
- **AI summaries**: Test with/without GITHUB_TOKEN (graceful degradation)
- **Environment customization**: Test with custom RSS_TITLE, RSS_DESCRIPTION, RSS_URLS

## Repository Structure

### Key Files and Directories
```
├── render.rb              # Main rendering script (9,517 lines)
├── test/render_test.rb     # Test suite (Minitest)
├── Gemfile                 # Ruby dependencies
├── Dockerfile             # Container definition
├── urls.txt               # Default RSS feed URLs
├── templates/             
│   ├── index.html.erb     # Main HTML template
│   └── manifest.json.erb  # PWA manifest template
├── public/                # Generated output directory
│   ├── index.html         # Generated HTML (gitignored)
│   ├── manifest.json      # Generated manifest (gitignored)
│   ├── main.css           # Stylesheet
│   └── img/               # Icons and assets
└── .github/workflows/     # CI/CD pipeline
```

### Environment Variables
Configure via environment variables:
```bash
# Required for custom feeds
export RSS_URLS="https://url1/feed,http://url2/rss"
export RSS_BACKUP_URLS="https://backup1/feed,http://backup2/rss"

# Optional customization
export RSS_TITLE="My News"
export RSS_DESCRIPTION="My really awesome news aggregation page"
export ANALYTICS_UA="UA-XXXXX-Y"

# Optional AI summaries (requires GitHub token)
export GITHUB_TOKEN="your_github_token_for_ai_summaries"
```

### CI/CD Pipeline (.github/workflows/)
- `render-test.yml`: Runs tests and code quality checks on PRs
- `docker.yml`: Builds Docker image
- `page.yml`: Deploys to GitHub Pages
- `bundle-up.yml`: Dependency updates
- `codeql.yml`: Security scanning
- `trivy-analysis.yml`: Container vulnerability scanning

## Common Tasks

### Development Workflow
1. Make code changes in `render.rb` or templates
2. Test locally: `ruby render.rb`
3. Validate: `ruby test/render_test.rb`
4. Review generated HTML in `public/index.html`
5. Commit changes (public files are gitignored)

### Adding New Tests
- Add tests to `test/render_test.rb`
- Follow existing Minitest patterns
- Test both success and error scenarios
- Validate HTML output structure

### Debugging Feed Issues
- Check network connectivity (feeds may be offline)
- Verify RSS_URLS format (comma-separated, valid URLs)
- Test with backup feeds: RSS_BACKUP_URLS
- Review render.rb output for error messages

### Performance Considerations
- Render script fetches RSS feeds in real-time (~3 seconds total)
- AI summaries cached for 6 hours (if GITHUB_TOKEN provided)
- Docker builds include Ruby gem installation (~2+ minutes)

## Known Issues and Workarounds

### Bundler Permission Issues
- Use manual gem installation instead of `bundle install`
- Install to user directory: `gem install --user-install`
- Add user gem path to PATH

### Network Restrictions
- RSS feeds may be inaccessible in sandboxed environments
- Docker builds may fail due to Alpine package manager restrictions
- Application gracefully handles network failures with placeholder content

### AI Summary Limitations
- Requires GitHub personal access token
- Falls back to "AI summarization unavailable" without token
- Summaries cached for 6 hours to minimize API usage

### Expected Error Messages (Normal Behavior)
These error messages are expected and handled gracefully:
```
General error with feed 'https://example.com/feed': Failed to open TCP connection
No GITHUB_TOKEN provided, skipping AI summarization
WARNING: fetching https://dl-cdn.alpinelinux.org/alpine: Permission denied (Docker build)
```

### Common Success Indicators
- Render completes with: "Successfully rendered HTML and manifest files."
- Tests complete with: "4 runs, 8 assertions, 0 failures, 0 errors, 0 skips"
- Generated HTML contains proper title tags and feed content or offline placeholders

## Timing Expectations

- **Gem installation**: 30 seconds (one-time setup)
- **Render script**: 3 seconds (NEVER CANCEL)
- **Test suite**: 3 seconds (NEVER CANCEL)  
- **Docker build**: 2-5 minutes when network available (NEVER CANCEL)

**CRITICAL**: Always wait for commands to complete. Do not cancel builds or tests that appear to hang - they typically complete within expected timeframes.