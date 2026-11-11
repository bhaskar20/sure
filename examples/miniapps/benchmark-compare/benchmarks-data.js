// Approximate calendar-year total returns, in percent, for a few well-known
// reference series. These are rounded public figures compiled for illustration,
// not an official data feed: check the index provider before relying on a
// number. The person can override any year, or add a custom benchmark, in the
// app; overrides are kept in the app's storage, never written back here.
//
// Equity and bond figures are in US dollars and include reinvested income.
// No fees, taxes or fund tracking error are deducted.
((root) => {
  const AS_OF_YEAR = 2025;

  const data = {
    asOfYear: AS_OF_YEAR,
    note: "Approximate annual total returns, rounded to 0.1%. Compiled from public index data for illustration; not investment advice.",
    benchmarks: [
      {
        id: "us-large-cap",
        name: "US large caps (S&P 500)",
        source: "S&P Dow Jones Indices, S&P 500 total return, USD",
        currency: "USD",
        returns: {
          2000: -9.1, 2001: -11.9, 2002: -22.1, 2003: 28.7, 2004: 10.9,
          2005: 4.9, 2006: 15.8, 2007: 5.5, 2008: -37.0, 2009: 26.5,
          2010: 15.1, 2011: 2.1, 2012: 16.0, 2013: 32.4, 2014: 13.7,
          2015: 1.4, 2016: 12.0, 2017: 21.8, 2018: -4.4, 2019: 31.5,
          2020: 18.4, 2021: 28.7, 2022: -18.1, 2023: 26.3, 2024: 25.0,
          2025: 17.9,
        },
      },
      {
        id: "global-equity",
        name: "Global stocks (MSCI ACWI)",
        source: "MSCI, ACWI net total return, USD",
        currency: "USD",
        returns: {
          2000: -14.2, 2001: -16.2, 2002: -19.3, 2003: 34.0, 2004: 15.2,
          2005: 10.8, 2006: 21.0, 2007: 11.7, 2008: -42.2, 2009: 34.6,
          2010: 12.7, 2011: -7.3, 2012: 16.1, 2013: 22.8, 2014: 4.2,
          2015: -2.4, 2016: 7.9, 2017: 24.0, 2018: -9.4, 2019: 26.6,
          2020: 16.3, 2021: 18.5, 2022: -18.4, 2023: 22.2, 2024: 17.5,
          2025: 22.3,
        },
      },
      {
        id: "us-agg-bonds",
        name: "US bonds (Bloomberg US Aggregate)",
        source: "Bloomberg, US Aggregate Bond Index total return, USD",
        currency: "USD",
        returns: {
          2000: 11.6, 2001: 8.4, 2002: 10.3, 2003: 4.1, 2004: 4.3,
          2005: 2.4, 2006: 4.3, 2007: 7.0, 2008: 5.2, 2009: 5.9,
          2010: 6.5, 2011: 7.8, 2012: 4.2, 2013: -2.0, 2014: 6.0,
          2015: 0.5, 2016: 2.6, 2017: 3.5, 2018: 0.0, 2019: 8.7,
          2020: 7.5, 2021: -1.5, 2022: -13.0, 2023: 5.5, 2024: 1.3,
          2025: 7.3,
        },
      },
      {
        id: "sixty-forty",
        name: "60/40 (60% S&P 500, 40% US Aggregate)",
        source: "Derived: 60% S&P 500 and 40% US Aggregate, rebalanced each January",
        currency: "USD",
        blend: [
          { id: "us-large-cap", weight: 0.6 },
          { id: "us-agg-bonds", weight: 0.4 },
        ],
      },
      {
        id: "us-cpi",
        name: "US inflation (CPI-U)",
        source: "US Bureau of Labor Statistics, CPI-U, December to December",
        currency: "USD",
        returns: {
          2000: 3.4, 2001: 1.6, 2002: 2.4, 2003: 1.9, 2004: 3.3,
          2005: 3.4, 2006: 2.5, 2007: 4.1, 2008: 0.1, 2009: 2.7,
          2010: 1.5, 2011: 3.0, 2012: 1.7, 2013: 1.5, 2014: 0.8,
          2015: 0.7, 2016: 2.1, 2017: 2.1, 2018: 1.9, 2019: 2.3,
          2020: 1.4, 2021: 7.0, 2022: 6.5, 2023: 3.4, 2024: 2.9,
          2025: 2.7,
        },
      },
      {
        id: "cash",
        name: "Cash (3-month US Treasury bills)",
        source: "US Treasury 3-month bill, annual total return, USD",
        currency: "USD",
        returns: {
          2000: 5.8, 2001: 3.8, 2002: 1.6, 2003: 1.0, 2004: 1.4,
          2005: 3.2, 2006: 4.8, 2007: 4.7, 2008: 1.5, 2009: 0.1,
          2010: 0.1, 2011: 0.0, 2012: 0.1, 2013: 0.0, 2014: 0.0,
          2015: 0.0, 2016: 0.3, 2017: 0.9, 2018: 1.9, 2019: 2.1,
          2020: 0.4, 2021: 0.0, 2022: 1.5, 2023: 5.0, 2024: 5.2,
          2025: 4.2,
        },
      },
    ],
  };

  if (typeof module === "object" && module.exports) {
    module.exports = data;
  } else {
    root.BENCHMARK_DATA = data;
  }
})(globalThis);
