/// Douban's image CDN rejects Dart's default user agent even with a Referer.
/// Identify the application explicitly for catalogue and recommendation posters.
const doubanImageHeaders = {
  'User-Agent': 'NAKUPlayer/1.4.0',
  'Referer': 'https://m.douban.com/',
};
