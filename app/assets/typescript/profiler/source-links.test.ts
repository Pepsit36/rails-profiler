import { describe, expect, it } from 'vitest'
import { buildEditorUrl, mapPath, parseFrame } from './source-links'

describe('buildEditorUrl', () => {
  const file = '/home/me/project/app/models/user.rb'

  it('builds the vscode URL', () => {
    expect(buildEditorUrl(file, 12, { scheme: 'vscode' })).toBe('vscode://file/home/me/project/app/models/user.rb:12')
  })

  it('builds the cursor URL', () => {
    expect(buildEditorUrl(file, 12, { scheme: 'cursor' })).toBe('cursor://file/home/me/project/app/models/user.rb:12')
  })

  it('builds the idea URL', () => {
    expect(buildEditorUrl(file, 12, { scheme: 'idea' })).toBe(
      'idea://open?file=%2Fhome%2Fme%2Fproject%2Fapp%2Fmodels%2Fuser.rb&line=12',
    )
  })

  it('escapes the characters that would end the path or the query', () => {
    expect(buildEditorUrl('/srv/my app/a&b#c?.rb', 3, { scheme: 'vscode' })).toBe('vscode://file/srv/my%20app/a%26b%23c%3F.rb:3')
    expect(buildEditorUrl('/srv/a&line=1#.rb', 3, { scheme: 'idea' })).toBe(
      'idea://open?file=%2Fsrv%2Fa%26line%3D1%23.rb&line=3',
    )
  })

  it('accepts a Windows host path', () => {
    expect(buildEditorUrl('C:\\proj\\a.rb', 5, { scheme: 'vscode' })).toBe('vscode://file/C:/proj/a.rb:5')
  })

  it.each(['javascript', 'JAVASCRIPT:alert(1)//', 'data', 'file', 'vscode://evil', 'http', '', null, undefined])(
    'builds no link for the scheme %s',
    (scheme) => {
      expect(buildEditorUrl(file, 12, { scheme })).toBeNull()
    },
  )

  it('builds no link for a relative path or an invalid line', () => {
    expect(buildEditorUrl('app/models/user.rb', 12, { scheme: 'vscode' })).toBeNull()
    expect(buildEditorUrl(file, 0, { scheme: 'vscode' })).toBeNull()
    expect(buildEditorUrl(file, 1.5, { scheme: 'vscode' })).toBeNull()
    expect(buildEditorUrl(file, NaN, { scheme: 'vscode' })).toBeNull()
  })

  it('translates the container path before building the URL', () => {
    expect(buildEditorUrl('/app/models/user.rb', 7, { scheme: 'vscode', pathMap: { '/app': '/home/me/projet' } })).toBe(
      'vscode://file/home/me/projet/models/user.rb:7',
    )
  })
})

describe('mapPath', () => {
  const map = { '/app': '/home/me/projet', '/app/vendor': '/opt/vendor' }

  it('translates a container path', () => {
    expect(mapPath('/app/models/user.rb', map)).toBe('/home/me/projet/models/user.rb')
  })

  it('applies the longest matching prefix', () => {
    expect(mapPath('/app/vendor/x.rb', map)).toBe('/opt/vendor/x.rb')
  })

  it('leaves a path no entry matches unchanged', () => {
    expect(mapPath('/home/me/other/x.rb', map)).toBe('/home/me/other/x.rb')
  })

  it('matches on a segment boundary only', () => {
    expect(mapPath('/application/x.rb', map)).toBe('/application/x.rb')
  })

  it('ignores a missing map', () => {
    expect(mapPath('/app/x.rb', undefined)).toBe('/app/x.rb')
    expect(mapPath('/app/x.rb', {})).toBe('/app/x.rb')
  })
})

describe('parseFrame', () => {
  it('splits a backtrace line', () => {
    expect(parseFrame("/app/models/user.rb:12:in `save'")).toEqual({ file: '/app/models/user.rb', line: 12 })
    expect(parseFrame('/app/a.rb:3')).toEqual({ file: '/app/a.rb', line: 3 })
  })

  it('returns null without a line', () => {
    expect(parseFrame('no line here')).toBeNull()
  })
})
