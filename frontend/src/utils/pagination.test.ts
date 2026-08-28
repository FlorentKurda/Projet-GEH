import { describe, expect, it } from 'vitest';
import { getPaginationItems } from './pagination';

describe('pagination items', () => {
  it('returns every page for short catalogs', () => {
    expect(getPaginationItems(2, 4)).toEqual([1, 2, 3, 4]);
  });

  it('condenses a large catalog around the active page', () => {
    expect(getPaginationItems(10, 20)).toEqual([
      1,
      'ellipsis-start',
      9,
      10,
      11,
      'ellipsis-end',
      20,
    ]);
  });

  it('keeps useful neighbors near each boundary', () => {
    expect(getPaginationItems(1, 20)).toEqual([1, 2, 'ellipsis-end', 20]);
    expect(getPaginationItems(20, 20)).toEqual([1, 'ellipsis-start', 19, 20]);
  });
});
