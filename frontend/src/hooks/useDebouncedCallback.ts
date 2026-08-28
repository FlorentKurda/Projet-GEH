import { useCallback, useEffect, useRef } from 'react';

export function useDebouncedCallback<T extends unknown[]>(
  callback: (...arguments_: T) => void,
  delayMilliseconds: number,
) {
  const callbackRef = useRef(callback);
  const timeoutRef = useRef<number | null>(null);

  useEffect(() => {
    callbackRef.current = callback;
  }, [callback]);

  const cancel = useCallback(() => {
    if (timeoutRef.current !== null) {
      window.clearTimeout(timeoutRef.current);
      timeoutRef.current = null;
    }
  }, []);

  const schedule = useCallback(
    (...arguments_: T) => {
      cancel();
      timeoutRef.current = window.setTimeout(() => {
        timeoutRef.current = null;
        callbackRef.current(...arguments_);
      }, delayMilliseconds);
    },
    [cancel, delayMilliseconds],
  );

  useEffect(() => cancel, [cancel]);

  return { schedule, cancel };
}
