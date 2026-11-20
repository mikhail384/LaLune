(() => {
  'use strict';

  const OWNER = 'Endlad2';
  const REPO = 'LaLune';
  const API = `https://api.github.com/repos/${OWNER}/${REPO}`;
  const CACHE_KEY = 'lalune-site-github-cache-v2';
  const CACHE_TTL = 10 * 60 * 1000;

  const el = (id) => document.getElementById(id);
  const fmt = new Intl.NumberFormat('ru-RU');

  function setText(id, value) {
    const node = el(id);
    if (node) node.textContent = value;
  }

  function setHref(id, value) {
    const node = el(id);
    if (node && value) node.href = value;
  }

  function formatDate(value) {
    if (!value) return 'GitHub Releases';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return 'GitHub Releases';
    return new Intl.DateTimeFormat('ru-RU', {
      day: '2-digit',
      month: 'long',
      year: 'numeric',
    }).format(date);
  }

  function parseLastPage(linkHeader) {
    if (!linkHeader) return null;
    const match = linkHeader.match(/[?&]page=(\d+)>; rel="last"/);
    return match ? Number(match[1]) : null;
  }

  async function request(url) {
    const response = await fetch(url, {
      headers: { Accept: 'application/vnd.github+json' },
    });
    if (!response.ok) throw new Error(`GitHub API: ${response.status}`);
    return response;
  }

  async function fetchCommitCount() {
    const response = await request(`${API}/commits?per_page=1`);
    const data = await response.json();
    const lastPage = parseLastPage(response.headers.get('Link'));
    if (lastPage !== null) return lastPage;
    return Array.isArray(data) ? data.length : 0;
  }

  async function fetchGithubData() {
    const [repoResponse, releaseResponse, contributorsResponse, commits] = await Promise.all([
      request(API),
      request(`${API}/releases/latest`),
      request(`${API}/contributors?per_page=100&anon=1`),
      fetchCommitCount(),
    ]);

    const [repo, release, contributorsRaw] = await Promise.all([
      repoResponse.json(),
      releaseResponse.json(),
      contributorsResponse.json(),
    ]);

    const contributors = (Array.isArray(contributorsRaw) ? contributorsRaw : [])
      .filter((item) => item && item.type !== 'Bot' && item.login && item.html_url && item.avatar_url)
      .map((item) => ({
        login: item.login,
        avatar: item.avatar_url,
        url: item.html_url,
        contributions: Number(item.contributions) || 0,
      }));

    return {
      stars: Number(repo.stargazers_count) || 0,
      commits: Number(commits) || 0,
      contributors,
      release: {
        tag: release.tag_name || release.name || 'latest',
        url: release.html_url || `https://github.com/${OWNER}/${REPO}/releases/latest`,
        publishedAt: release.published_at || release.created_at || null,
      },
      fetchedAt: Date.now(),
    };
  }

  function readCache() {
    try {
      const parsed = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
      if (!parsed || !parsed.fetchedAt) return null;
      if (Date.now() - parsed.fetchedAt > CACHE_TTL) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  function writeCache(data) {
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(data)); } catch (_) {}
  }

  function renderContributors(contributors) {
    const grid = el('contributorsGrid');
    if (!grid) return;
    grid.innerHTML = '';

    if (!contributors.length) {
      const empty = document.createElement('div');
      empty.className = 'empty-state';
      empty.textContent = 'GitHub временно не вернул список контрибьютеров.';
      grid.appendChild(empty);
      return;
    }

    const fragment = document.createDocumentFragment();
    contributors.forEach((person) => {
      const link = document.createElement('a');
      link.className = 'contributor-card';
      link.href = person.url;
      link.target = '_blank';
      link.rel = 'noreferrer';
      link.setAttribute('aria-label', `${person.login} на GitHub`);

      const avatar = document.createElement('img');
      avatar.className = 'contributor-avatar';
      avatar.src = person.avatar;
      avatar.alt = '';
      avatar.width = 54;
      avatar.height = 54;
      avatar.loading = 'lazy';

      const meta = document.createElement('span');
      meta.className = 'contributor-meta';

      const name = document.createElement('span');
      name.className = 'contributor-name';
      name.textContent = person.login;

      const count = document.createElement('span');
      count.className = 'contributor-count';
      count.textContent = `${fmt.format(person.contributions)} вкладов`;

      meta.append(name, count);
      link.append(avatar, meta);
      fragment.appendChild(link);
    });
    grid.appendChild(fragment);
  }

  function render(data) {
    setText('starsCount', fmt.format(data.stars));
    setText('commitsCount', fmt.format(data.commits));
    setText('contributorsCount', fmt.format(data.contributors.length));
    setText('latestTag', data.release.tag);
    setText('latestDate', formatDate(data.release.publishedAt));
    setText('releaseMeta', `${data.release.tag} · ${formatDate(data.release.publishedAt)}`);
    setText('releaseCardMeta', `${data.release.tag} · ${formatDate(data.release.publishedAt)}`);
    setHref('heroReleaseLink', data.release.url);
    setHref('latestReleaseCard', data.release.url);
    renderContributors(data.contributors);
  }

  function renderApiFailure() {
    setText('releaseMeta', 'GitHub API временно недоступен. Ссылка latest остаётся рабочей.');
    const grid = el('contributorsGrid');
    if (grid) {
      grid.innerHTML = '<div class="empty-state">Не удалось загрузить данные GitHub. Обнови страницу позже.</div>';
    }
  }

  function initReveal() {
    const nodes = document.querySelectorAll('[data-reveal]');
    nodes.forEach((node) => {
      const delay = node.getAttribute('data-delay');
      if (delay) node.style.setProperty('--delay', `${delay}ms`);
    });

    if (!('IntersectionObserver' in window)) {
      nodes.forEach((node) => node.classList.add('is-visible'));
      return;
    }

    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -30px 0px' });

    nodes.forEach((node) => observer.observe(node));
  }

  async function initGithub() {
    const cached = readCache();
    if (cached) {
      render(cached);
      return;
    }

    try {
      const data = await fetchGithubData();
      render(data);
      writeCache(data);
    } catch (error) {
      console.warn('LaLune site: failed to load GitHub data', error);
      renderApiFailure();
    }
  }

  initReveal();
  initGithub();
})();
