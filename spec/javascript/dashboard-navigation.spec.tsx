import { describe, expect, it } from 'vitest'

describe('Dashboard Navigation', () => {
  describe('Case 1: pushState without popstate handler – replaced with replaceState', () => {
    it('ProfileList.tsx:258 – handleSectionChange uses replaceState', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/ProfileList.tsx', 'utf-8')
      expect(code).toContain('history.replaceState(null, \'\', url.toString())')
      expect(code.match(/history\.pushState/g)?.length || 0).toBeLessThan(2)
    })

    it('ProfileDashboard.tsx:47 – handleTabClick uses replaceState', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/dashboard/ProfileDashboard.tsx', 'utf-8')
      expect(code.match(/handleTabClick = \(.*?\) => \(.*?\) => \{[^}]*history\.replaceState/s)).toBeTruthy()
    })

    it('JobProfileDashboard.tsx:46 – handleTabClick uses replaceState', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/dashboard/JobProfileDashboard.tsx', 'utf-8')
      expect(code.match(/handleTabClick = \(.*?\) => \(.*?\) => \{[^}]*history\.replaceState/s)).toBeTruthy()
    })
  })

  describe('Case 2: Load more deduplicates by token', () => {
    it('ProfileList.tsx – deduplicateByToken function exists', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/ProfileList.tsx', 'utf-8')
      expect(code).toContain('deduplicateByToken')
      expect(code).toContain('seen.has(item.token)')
    })

    it('ProfileList.tsx – profiles are deduplicated', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/ProfileList.tsx', 'utf-8')
      expect(code).toContain('const profiles        = deduplicateByToken')
      expect(code).toContain('const jobs            = deduplicateByToken')
      expect(code).toContain('const consoles        = deduplicateByToken')
      expect(code).toContain('const tests           = deduplicateByToken')
    })
  })

  describe('Case 3: ProfileDashboard respects ?tab= parameter', () => {
    it('ProfileDashboard.tsx – reads tab from URL', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/dashboard/ProfileDashboard.tsx', 'utf-8')
      expect(code).toContain('const urlParams = new URLSearchParams(window.location.search)')
      expect(code).toContain('const tabFromUrl = urlParams.get(\'tab\')')
      expect(code).toContain('tabFromUrl ? (tabFromUrl as TabKey) : (hasException ? \'exception\' : initialTab)')
    })

    it('JobProfileDashboard.tsx – reads tab from URL', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/dashboard/JobProfileDashboard.tsx', 'utf-8')
      expect(code).toContain('const urlParams = new URLSearchParams(window.location.search)')
      expect(code).toContain('const tabFromUrl = urlParams.get(\'tab\')')
      expect(code).toContain('validTabs.includes(tabFromUrl as JobTabKey) ? (tabFromUrl as JobTabKey) :')
    })
  })

  describe('Case 4: Version banner in English', () => {
    it('ProfileDashboard.tsx – version banner is in English', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/dashboard/ProfileDashboard.tsx', 'utf-8')
      expect(code).toContain('Profile captured with version')
      expect(code).toContain('current version:')
      expect(code).not.toContain('Profil capturé')
      expect(code).not.toContain('version actuelle')
    })

    it('JobProfileDashboard.tsx – version banner is in English', () => {
      const code = require('fs').readFileSync('/workspace/app/assets/typescript/profiler/components/dashboard/JobProfileDashboard.tsx', 'utf-8')
      expect(code).toContain('Profile captured with version')
      expect(code).toContain('current version:')
      expect(code).not.toContain('Profil capturé')
      expect(code).not.toContain('version actuelle')
    })
  })
})
