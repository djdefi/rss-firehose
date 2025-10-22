## rss-firehose

Aggregate Local RSS feeds into a lightweight page.

Example page: https://djdefi.github.io/rss-firehose/

### Rendering:

To render the page:

```
ruby render.rb
```

Outputs to: `public/index.html`

### Writing and Running Rendering Tests

To ensure the integrity of rendering changes, it's crucial to write and run rendering tests. Here's how:

1. Write new tests in `test/render_test.rb` when modifying rendering logic.
2. To run the tests, execute the following command:

```
ruby test/render_test.rb
```

This will verify that the output of `render.rb` matches the expected HTML structure or content.

### Docker

To run the application using Docker, build the Docker image and then run the container:

```
docker build -t djdefi/rss-firehose .
docker run --rm -v rss-firehose:/usr/src/app/public -it djdefi/rss-firehose
```

Re-run the `rss-firehose` container to update the page.

#### Environment variables

Optional settings can be configured an Docker run time, or be set in your local Ruby environment:

```

## Docker:

docker run --rm -v rss-firehose:/usr/src/app/public -e "RSS_TITLE=My News" -e "RSS_URLS=https://url1/feed,http://url2/rss" -e "RSS_BACKUP_URLS=https://backup1/feed,http://backup2/rss" -e "ANALYTICS_UA=UA-XXXXX-Y" -it djdefi/rss-firehose

## Ruby:

export RSS_URLS="https://url1/feed,http://url2/rss"
export RSS_BACKUP_URLS="https://backup1/feed,http://backup2/rss"
ruby render.rb

```

Available environment variable options:

```
"ANALYTICS_UA=UA-XXXXX-Y"
"RSS_URLS=https://url1/feed,http://url2/rss"
"RSS_BACKUP_URLS=https://backup1/feed,http://backup2/rss"
"RSS_TITLE=My News"
"RSS_DESCRIPTION=My really awesome news aggregation page"
"GITHUB_TOKEN=your_github_token_for_ai_summaries"
"FORCE_REGENERATE=true" # Skip cache and force full regeneration
```

### AI-Powered Summaries

RSS Firehose can generate AI-powered summaries of your news feeds using GitHub's Models service. To enable this feature:

1. Set the `GITHUB_TOKEN` environment variable with your GitHub personal access token
2. Summaries are cached for 6 hours to minimize API usage
3. If no token is provided, the app gracefully falls back to displaying feeds without summaries

#### Forcing Full Regeneration

By default, AI summaries are cached for 6 hours. To force a full regeneration of the feed (skipping the cache):

**GitHub Actions Workflow Dispatch:**
1. Go to the Actions tab in your GitHub repository
2. Select the "Auto pages deploy" workflow
3. Click "Run workflow"
4. Select "true" for the "Force full regeneration (skip cache)" option
5. Click "Run workflow"

**Local Development:**
```bash
FORCE_REGENERATE=true ruby render.rb
```

This is useful when you want to refresh the content on demand, even if the cached summary is still valid.

#### Summary Variation Features

The system generates two distinct types of summaries with different approaches:

**Individual Feed Summaries**
- Focus on unique aspects and specific details of each news source
- Use engaging language with varied sentence structure  
- Highlight what makes each feed distinctive
- Higher creativity setting for more varied output

**Overall Summary**
- Provides big-picture analysis across all news sources
- Identifies themes, patterns, and trends 
- Uses analytical language emphasizing implications and context
- Focuses on connections between stories rather than individual details

This dual approach ensures varied and interesting content rather than repetitive summaries.

### Features

- **Robust Error Handling**: Feeds that are offline or unreachable are gracefully handled with placeholder content
- **Smart Backup Feeds**: Configure backup RSS feeds that are used when primary feeds are empty
- **AI Summarization**: Optional AI-powered news summaries using GitHub Models
- **Caching**: Intelligent caching of AI summaries to reduce API usage
- **Input Validation**: Automatic validation of RSS URLs and configuration
- **Responsive Design**: Mobile-friendly HTML output with accessibility features
