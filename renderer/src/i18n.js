import chinese from './locales/zh-Hans.json' with { type: 'json' }

// The native app supplies its selected bundle language on every render. This
// also lets Quick Look use the same language as its containing app.
let language = 'en'
export function setLanguage(preferred = 'en') {
  language = /^zh(?:-Hans|-CN|-SG|$)/i.test(preferred) ? 'zh-Hans' : 'en'
  document.documentElement.lang = language
}

export const currentLanguage = () => language

export function t(key, values = {}) {
  const template = language === 'zh-Hans' ? (chinese[key] ?? key) : key
  return template.replace(/\{(\w+)\}/g, (match, name) =>
    Object.hasOwn(values, name) ? String(values[name]) : match)
}
