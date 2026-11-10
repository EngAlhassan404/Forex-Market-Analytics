//+------------------------------------------------------------------+
//|                                     MarketVolatilityScanner.mq5  |
//|                Copyright 2026, Eng.Alhassan Ali Mubarak Bahbah   |
//+------------------------------------------------------------------+
#property copyright "Eng.Alhassan Ali Mubarak Bahbah"
#property link      ""
#property version   "1.00"
#property description "Multi-Asset Volatility & Expansion Scanner Engine for MT5"

//--- Struct to hold individual symbol volatility metrics
struct SymbolVolatility
{
   string symbol;          // Symbol name
   double openPrice;       // Today Open
   double highPrice;       // Today High
   double lowPrice;        // Today Low
   double pctRange;        // (High - Low) / Open * 100
   double adr14;           // 14-day Average Daily Range in pips
   double todayRange;      // Today Range in pips
   double expansionRatio;  // Today Range / ADR14
   bool   isHot;           // True if expansion >= threshold
};

//--- Input Parameters
input group "=== Multi-Asset Scanner Settings ==="
// Comma-separated list of symbols (Default includes '.s' suffix as requested)
input string InpSymbols          = "XAUUSD.s, EURUSD.s, GBPUSD.s, USDJPY.s, AUDUSD.s, NZDUSD.s, USDCAD.s, USDCHF.s, GBPJPY.s";
input int    InpADRPeriod        = 14;     // ADR Average Period (Days)
input double InpHotThreshold     = 1.0;    // Hot/Volatile Threshold (Expansion Ratio >= 1.0)
input double InpQuietThreshold   = 0.6;    // Quiet/Dead Threshold (Expansion Ratio <= 0.6)

input group "=== Visual Panel Settings ==="
input int    InpPanelX           = 30;               // Initial Panel X Position
input int    InpPanelY           = 40;               // Initial Panel Y Position
input color  InpHeaderBg         = C'31,78,121';     // Header Color (Navy Blue)
input color  InpHeaderTextColor  = clrWhite;         // Header Text Color
input color  InpBodyBg           = clrWhite;         // Panel Background
input color  InpBorderColor      = C'200,200,200';   // Border Color
input color  InpHotColor         = C'0,150,70';      // Green Color for Volatile Assets
input color  InpQuietColor       = C'192,0,0';       // Red Color for Quiet Assets
input color  InpNormalColor      = C'50,50,50';      // Dark Neutral Color

//--- Global Variables
string   g_Prefix        = "MVS_";
int      g_PanelX        = 30;
int      g_PanelY        = 40;
int      g_PanelWidth    = 460;
int      g_PanelHeight   = 360;
int      g_HeaderHeight  = 30;
bool     g_IsCollapsed   = false;
bool     g_IsDragging    = false;
int      g_DragOffsetX   = 0;
int      g_DragOffsetY   = 0;

string   g_Symbols[];             // Parsed symbol list
SymbolVolatility g_Metrics[];     // Calculated metrics array

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_PanelX = InpPanelX;
   g_PanelY = InpPanelY;

   // Parse Input Symbols
   ParseSymbols();

   if(ArraySize(g_Symbols) == 0)
   {
      Print("Error: No valid symbols provided in input!");
      return(INIT_FAILED);
   }

   // Enable chart mouse events & Timer
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   EventSetTimer(1); // Update scanner every 1 second

   // Initial Scanning & UI Build
   ScanAllSymbols();
   CreateDashboard();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, g_Prefix);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Timer event for dynamic live scanning and auto-sorting           |
//+------------------------------------------------------------------+
void OnTimer()
{
   ScanAllSymbols();
   UpdateDashboardValues();
}

//+------------------------------------------------------------------+
//| Parse input string separated by commas                           |
//+------------------------------------------------------------------+
void ParseSymbols()
{
   ushort u_sep = StringGetCharacter(",", 0);
   StringSplit(InpSymbols, u_sep, g_Symbols);

   int count = ArraySize(g_Symbols);
   for(int i = 0; i < count; i++)
   {
      StringTrimLeft(g_Symbols[i]);
      StringTrimRight(g_Symbols[i]);
      
      // Ensure symbol is selected in Market Watch for background calculations
      if(g_Symbols[i] != "")
         SymbolSelect(g_Symbols[i], true);
   }
}

//+------------------------------------------------------------------+
//| Helper to calculate point/pip divider for background symbol      |
//+------------------------------------------------------------------+
double GetSymbolUnitDivider(const string sym)
{
   long digits = SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   if(digits == 3 || digits == 5)
      return point * 10.0; // Pip
   
   return point; // Raw Point
}

//+------------------------------------------------------------------+
//| Scan and calculate metrics for all configured symbols            |
//+------------------------------------------------------------------+
void ScanAllSymbols()
{
   int total = ArraySize(g_Symbols);
   if(total == 0) return;

   ArrayResize(g_Metrics, total);

   for(int i = 0; i < total; i++)
   {
      string sym = g_Symbols[i];
      g_Metrics[i].symbol = sym;

      if(sym == "" || !SymbolInfoInteger(sym, SYMBOL_SELECT))
         continue;

      // Fetch D1 rates (Today bar [0] + Past 14 bars)
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(sym, PERIOD_D1, 0, InpADRPeriod + 1, rates);

      if(copied < 2) continue; // Need at least today + historical data

      double openToday = rates[0].open;
      double highToday = rates[0].high;
      double lowToday  = rates[0].low;
      double unitDiv   = GetSymbolUnitDivider(sym);

      if(openToday <= 0 || unitDiv <= 0) continue;

      // Percentage Range Today
      g_Metrics[i].pctRange = ((highToday - lowToday) / openToday) * 100.0;
      g_Metrics[i].todayRange = (highToday - lowToday) / unitDiv;

      // Calculate ADR (14)
      double sumRange = 0.0;
      int adrCount = MathMin(copied - 1, InpADRPeriod);

      for(int j = 1; j <= adrCount; j++)
      {
         sumRange += (rates[j].high - rates[j].low) / unitDiv;
      }

      g_Metrics[i].adr14 = (adrCount > 0) ? (sumRange / adrCount) : 1.0;

      // Expansion Ratio = Today Range / ADR
      g_Metrics[i].expansionRatio = (g_Metrics[i].adr14 > 0) ? (g_Metrics[i].todayRange / g_Metrics[i].adr14) : 0.0;
      g_Metrics[i].isHot          = (g_Metrics[i].expansionRatio >= InpHotThreshold);
   }

   // Dynamic Sorting: Sort array in descending order based on Expansion Ratio
   SortMetricsDescending();
}

//+------------------------------------------------------------------+
//| Bubble Sort for metrics array (Descending by Expansion Ratio)    |
//+------------------------------------------------------------------+
void SortMetricsDescending()
{
   int n = ArraySize(g_Metrics);
   for(int i = 0; i < n - 1; i++)
   {
      for(int j = 0; j < n - i - 1; j++)
      {
         if(g_Metrics[j].expansionRatio < g_Metrics[j + 1].expansionRatio)
         {
            // Swap
            SymbolVolatility temp = g_Metrics[j];
            g_Metrics[j] = g_Metrics[j + 1];
            g_Metrics[j + 1] = temp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| GUI Dashboard Creation                                          |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   CreateRectLabel("BgFrame", g_PanelX, g_PanelY, g_PanelWidth, g_PanelHeight, InpBodyBg, InpBorderColor, 1);
   CreateRectLabel("HeaderBg", g_PanelX, g_PanelY, g_PanelWidth, g_HeaderHeight, InpHeaderBg, InpHeaderBg, 0);
   CreateLabel("HeaderTitle", "MULTI-ASSET VOLATILITY SCANNER", g_PanelX + 12, g_PanelY + 6, InpHeaderTextColor, 9, true);
   CreateButton("BtnCollapse", "[-]", g_PanelX + g_PanelWidth - 28, g_PanelY + 4, 22, 20, InpHeaderBg, clrWhite);

   CreateLabel("lblSubTitle", "Real-Time Expansion & Volatility Ranking Engine", g_PanelX + 12, g_PanelY + 34, C'100,100,100', 8, false);

   // Table Header
   int startY = g_PanelY + 52;
   CreateRectLabel("TblHeaderBg", g_PanelX + 10, startY, g_PanelWidth - 20, 20, C'240,243,246', C'220,224,230', 1);
   CreateLabel("thRank",   "Rank",         g_PanelX + 15,  startY + 3, C'80,80,80', 8, true);
   CreateLabel("thSymbol", "Asset Symbol", g_PanelX + 60,  startY + 3, C'80,80,80', 8, true);
   CreateLabel("thPct",    "% Range",      g_PanelX + 175, startY + 3, C'80,80,80', 8, true);
   CreateLabel("thExp",    "Expansion",    g_PanelX + 265, startY + 3, C'80,80,80', 8, true);
   CreateLabel("thStatus", "Market State", g_PanelX + 360, startY + 3, C'80,80,80', 8, true);

   // 9 Rows for Assets
   int rowStartY = startY + 22;
   for(int i = 0; i < 9; i++)
   {
      int currentY = rowStartY + (i * 26);
      string sIndex = IntegerToString(i);

      CreateRectLabel("RowBg_" + sIndex, g_PanelX + 10, currentY, g_PanelWidth - 20, 24, clrWhite, C'235,235,235', 1);
      CreateLabel("valRank_"   + sIndex, "#" + IntegerToString(i + 1), g_PanelX + 18,  currentY + 4, C'120,120,120', 8, false);
      CreateLabel("valSymbol_" + sIndex, "---",                       g_PanelX + 60,  currentY + 4, InpNormalColor,  8, true);
      CreateLabel("valPct_"    + sIndex, "0.00%",                     g_PanelX + 175, currentY + 4, InpNormalColor,  8, false);
      CreateLabel("valExp_"    + sIndex, "0.00x",                     g_PanelX + 265, currentY + 4, InpNormalColor,  8, false);
      CreateLabel("valStatus_" + sIndex, "---",                       g_PanelX + 360, currentY + 4, InpNormalColor,  8, true);
   }

   CreateLabel("lblFooter", "Engineered by Eng.Alhassan Ali Mubarak Bahbah", g_PanelX + 12, g_PanelY + g_PanelHeight - 16, C'140,140,140', 7, false);

   UpdateDashboardValues();
}

//+------------------------------------------------------------------+
//| Update Dynamic Dashboard Values & Colors                         |
//+------------------------------------------------------------------+
void UpdateDashboardValues()
{
   int count = ArraySize(g_Metrics);
   int displayCount = MathMin(count, 9);

   for(int i = 0; i < displayCount; i++)
   {
      string sIndex = IntegerToString(i);

      color stateColor = InpNormalColor;
      string statusStr = "Normal";

      if(g_Metrics[i].expansionRatio >= InpHotThreshold)
      {
         stateColor = InpHotColor; // Green
         statusStr  = "HOT / Volatile";
      }
      else if(g_Metrics[i].expansionRatio <= InpQuietThreshold)
      {
         stateColor = InpQuietColor; // Red
         statusStr  = "QUIET / Dead";
      }

      ObjectSetString(0, g_Prefix + "valSymbol_" + sIndex, OBJPROP_TEXT, g_Metrics[i].symbol);
      ObjectSetString(0, g_Prefix + "valPct_"    + sIndex, OBJPROP_TEXT, StringFormat("%.2f%%", g_Metrics[i].pctRange));
      ObjectSetString(0, g_Prefix + "valExp_"    + sIndex, OBJPROP_TEXT, StringFormat("%.2fx", g_Metrics[i].expansionRatio));
      
      ObjectSetString(0,  g_Prefix + "valStatus_" + sIndex, OBJPROP_TEXT, statusStr);
      ObjectSetInteger(0, g_Prefix + "valStatus_" + sIndex, OBJPROP_COLOR, stateColor);
      ObjectSetInteger(0, g_Prefix + "valSymbol_" + sIndex, OBJPROP_COLOR, stateColor);
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| ChartEvent function for dragging & collapsing GUI                |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == g_Prefix + "BtnCollapse")
      {
         g_IsCollapsed = !g_IsCollapsed;
         ObjectSetString(0, g_Prefix + "BtnCollapse", OBJPROP_TEXT, g_IsCollapsed ? "[+]" : "[-]");
         UpdatePanelVisibility();
         ChartRedraw(0);
         return;
      }
   }

   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      int mouseX = (int)lparam;
      int mouseY = (int)dparam;
      uint mouseState = (uint)sparam;
      bool leftBtnPressed = ((mouseState & 1) == 1);

      if(leftBtnPressed && !g_IsDragging)
      {
         if(mouseX >= g_PanelX && mouseX <= (g_PanelX + g_PanelWidth - 30) &&
            mouseY >= g_PanelY && mouseY <= (g_PanelY + g_HeaderHeight))
         {
            g_IsDragging  = true;
            g_DragOffsetX = mouseX - g_PanelX;
            g_DragOffsetY = mouseY - g_PanelY;
            ChartSetInteger(0, CHART_MOUSE_SCROLL, false);
         }
      }

      if(g_IsDragging && leftBtnPressed)
      {
         int rawX = mouseX - g_DragOffsetX;
         int rawY = mouseY - g_DragOffsetY;
         int chartWidth  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
         int chartHeight = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
         int currentPanelHeight = g_IsCollapsed ? g_HeaderHeight : g_PanelHeight;

         g_PanelX = MathMax(0, MathMin(rawX, chartWidth - g_PanelWidth));
         g_PanelY = MathMax(0, MathMin(rawY, chartHeight - currentPanelHeight));

         RepositionDashboard();
         ChartRedraw(0);
      }

      if(!leftBtnPressed && g_IsDragging)
      {
         g_IsDragging = false;
         ChartSetInteger(0, CHART_MOUSE_SCROLL, true);
      }
   }
}

//+------------------------------------------------------------------+
//| Handle Panel Collapse / Expand                                   |
//+------------------------------------------------------------------+
void UpdatePanelVisibility()
{
   long tfVisibility = g_IsCollapsed ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS;

   ObjectSetInteger(0, g_Prefix + "lblSubTitle",  OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "TblHeaderBg",  OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thRank",       OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thSymbol",     OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thPct",        OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thExp",        OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thStatus",     OBJPROP_TIMEFRAMES, tfVisibility);

   for(int i = 0; i < 9; i++)
   {
      string sIndex = IntegerToString(i);
      ObjectSetInteger(0, g_Prefix + "RowBg_"   + sIndex, OBJPROP_TIMEFRAMES, tfVisibility);
      ObjectSetInteger(0, g_Prefix + "valRank_" + sIndex, OBJPROP_TIMEFRAMES, tfVisibility);
      ObjectSetInteger(0, g_Prefix + "valSymbol_"+ sIndex, OBJPROP_TIMEFRAMES, tfVisibility);
      ObjectSetInteger(0, g_Prefix + "valPct_"  + sIndex, OBJPROP_TIMEFRAMES, tfVisibility);
      ObjectSetInteger(0, g_Prefix + "valExp_"  + sIndex, OBJPROP_TIMEFRAMES, tfVisibility);
      ObjectSetInteger(0, g_Prefix + "valStatus_"+ sIndex, OBJPROP_TIMEFRAMES, tfVisibility);
   }

   ObjectSetInteger(0, g_Prefix + "lblFooter", OBJPROP_TIMEFRAMES, tfVisibility);

   int newHeight = g_IsCollapsed ? g_HeaderHeight : g_PanelHeight;
   ObjectSetInteger(0, g_Prefix + "BgFrame", OBJPROP_YSIZE, newHeight);
}

//+------------------------------------------------------------------+
//| Reposition Dashboard Objects                                     |
//+------------------------------------------------------------------+
void RepositionDashboard()
{
   ObjectSetInteger(0, g_Prefix + "BgFrame",     OBJPROP_XDISTANCE, g_PanelX);
   ObjectSetInteger(0, g_Prefix + "BgFrame",     OBJPROP_YDISTANCE, g_PanelY);
   ObjectSetInteger(0, g_Prefix + "HeaderBg",    OBJPROP_XDISTANCE, g_PanelX);
   ObjectSetInteger(0, g_Prefix + "HeaderBg",    OBJPROP_YDISTANCE, g_PanelY);
   ObjectSetInteger(0, g_Prefix + "HeaderTitle", OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "HeaderTitle", OBJPROP_YDISTANCE, g_PanelY + 6);
   ObjectSetInteger(0, g_Prefix + "BtnCollapse",  OBJPROP_XDISTANCE, g_PanelX + g_PanelWidth - 28);
   ObjectSetInteger(0, g_Prefix + "BtnCollapse",  OBJPROP_YDISTANCE, g_PanelY + 4);
   ObjectSetInteger(0, g_Prefix + "lblSubTitle", OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblSubTitle", OBJPROP_YDISTANCE, g_PanelY + 34);

   int startY = g_PanelY + 52;
   ObjectSetInteger(0, g_Prefix + "TblHeaderBg", OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "TblHeaderBg", OBJPROP_YDISTANCE, startY);
   ObjectSetInteger(0, g_Prefix + "thRank",      OBJPROP_XDISTANCE, g_PanelX + 15);
   ObjectSetInteger(0, g_Prefix + "thRank",      OBJPROP_YDISTANCE, startY + 3);
   ObjectSetInteger(0, g_Prefix + "thSymbol",    OBJPROP_XDISTANCE, g_PanelX + 60);
   ObjectSetInteger(0, g_Prefix + "thSymbol",    OBJPROP_YDISTANCE, startY + 3);
   ObjectSetInteger(0, g_Prefix + "thPct",       OBJPROP_XDISTANCE, g_PanelX + 175);
   ObjectSetInteger(0, g_Prefix + "thPct",       OBJPROP_YDISTANCE, startY + 3);
   ObjectSetInteger(0, g_Prefix + "thExp",       OBJPROP_XDISTANCE, g_PanelX + 265);
   ObjectSetInteger(0, g_Prefix + "thExp",       OBJPROP_YDISTANCE, startY + 3);
   ObjectSetInteger(0, g_Prefix + "thStatus",    OBJPROP_XDISTANCE, g_PanelX + 360);
   ObjectSetInteger(0, g_Prefix + "thStatus",    OBJPROP_YDISTANCE, startY + 3);

   int rowStartY = startY + 22;
   for(int i = 0; i < 9; i++)
   {
      int currentY = rowStartY + (i * 26);
      string sIndex = IntegerToString(i);
      ObjectSetInteger(0, g_Prefix + "RowBg_"   + sIndex, OBJPROP_XDISTANCE, g_PanelX + 10);
      ObjectSetInteger(0, g_Prefix + "RowBg_"   + sIndex, OBJPROP_YDISTANCE, currentY);
      ObjectSetInteger(0, g_Prefix + "valRank_" + sIndex, OBJPROP_XDISTANCE, g_PanelX + 18);
      ObjectSetInteger(0, g_Prefix + "valRank_" + sIndex, OBJPROP_YDISTANCE, currentY + 4);
      ObjectSetInteger(0, g_Prefix + "valSymbol_"+ sIndex, OBJPROP_XDISTANCE, g_PanelX + 60);
      ObjectSetInteger(0, g_Prefix + "valSymbol_"+ sIndex, OBJPROP_YDISTANCE, currentY + 4);
      ObjectSetInteger(0, g_Prefix + "valPct_"  + sIndex, OBJPROP_XDISTANCE, g_PanelX + 175);
      ObjectSetInteger(0, g_Prefix + "valPct_"  + sIndex, OBJPROP_YDISTANCE, currentY + 4);
      ObjectSetInteger(0, g_Prefix + "valExp_"  + sIndex, OBJPROP_XDISTANCE, g_PanelX + 265);
      ObjectSetInteger(0, g_Prefix + "valExp_"  + sIndex, OBJPROP_YDISTANCE, currentY + 4);
      ObjectSetInteger(0, g_Prefix + "valStatus_"+ sIndex, OBJPROP_XDISTANCE, g_PanelX + 360);
      ObjectSetInteger(0, g_Prefix + "valStatus_"+ sIndex, OBJPROP_YDISTANCE, currentY + 4);
   }

   ObjectSetInteger(0, g_Prefix + "lblFooter", OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblFooter", OBJPROP_YDISTANCE, g_PanelY + g_PanelHeight - 16);
}

//+------------------------------------------------------------------+
//| Object Helper Functions                                          |
//+------------------------------------------------------------------+
void CreateRectLabel(string name, int x, int y, int w, int h, color bg, color border, int borderWidth)
{
   string objName = g_Prefix + name;
   ObjectDelete(0, objName);
   ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, borderWidth);
   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
}

void CreateLabel(string name, string text, int x, int y, color clr, int fontSize, bool isBold)
{
   string objName = g_Prefix + name;
   ObjectDelete(0, objName);
   ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetString(0,  objName, OBJPROP_TEXT, text);
   ObjectSetString(0,  objName, OBJPROP_FONT, isBold ? "Segoe UI Bold" : "Segoe UI");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
}

void CreateButton(string name, string text, int x, int y, int w, int h, color bg, color clr)
{
   string objName = g_Prefix + name;
   ObjectDelete(0, objName);
   ObjectCreate(0, objName, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, h);
   ObjectSetString(0,  objName, OBJPROP_TEXT, text);
   ObjectSetString(0,  objName, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
}