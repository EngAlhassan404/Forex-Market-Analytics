//+------------------------------------------------------------------+
//|                                  CandleBehavioralAnalytics.mq5   |
//|                Copyright 2026, Eng.Alhassan Ali Mubarak Bahbah   |
//+------------------------------------------------------------------+
#property copyright "Eng.Alhassan Ali Mubarak Bahbah"
#property link      ""
#property version   "8.20"
#property description "Candle Behavioral Analytics - Predictive Expansion & Risk Excursion Engine + Dynamic Pips/Points Line Tooltips"

//--- Enums
enum ENUM_CALC_MODE
{
   MODE_BAR_COUNT,   // Specific Bar Count
   MODE_ALL_HISTORY  // Full Available History
};

enum ENUM_UNIT_TYPE
{
   UNIT_AUTO,        // Auto Detect (Recommended)
   UNIT_PIPS,        // Forex Pips (Standard 10-point pip for 3/5 digits)
   UNIT_POINTS       // Raw Points (Indices, Gold, Commodities)
};

//--- Input Parameters
input group "=== Historical Calculation Settings ==="
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_D1;        // Target Timeframe
input ENUM_CALC_MODE  InpCalcMode        = MODE_BAR_COUNT;   // Calculation Range Mode
input int              InpBarCount       = 100;              // Bar Count (If Specific Window selected)
input ENUM_UNIT_TYPE  InpUnitType        = UNIT_AUTO;        // Unit Measurement (Default: Auto Detect)
input double           InpSDMultiplier   = 1.0;              // Historical Standard Deviation Multiplier

input group "=== Predictive Analytics Settings ==="
input double           InpPredSDMultiplier = 1.0;            // Prediction SD Multiplier (Range = Mean +/- SD x Multiplier)

input group "=== Projection Lines Settings ==="
input bool             InpShowLines      = true;             // Show Projection Lines (Master Switch)
input bool             InpShowBullLines  = true;             // Show Bullish Lines (MFE + MAE)
input bool             InpShowBearLines  = true;             // Show Bearish Lines (MFE + MAE)
input color            InpBullLineColor  = clrDodgerBlue;    // Bullish Lines Color (MFE solid / MAE dashed)
input color            InpBearLineColor  = clrRed;           // Bearish Lines Color (MFE solid / MAE dashed)
input int              InpLineWidth      = 1;                // MFE Line Width (MAE dashed lines are always width 1)
input bool             InpFullWidthLines = false;            // Full-Width Lines (false = current period only)
input bool             InpShowLineLabels = true;             // Show Text Labels Next To Lines

input group "=== Visual Panel Settings ==="
input int              InpPanelX         = 30;               // Initial Panel X Position
input int              InpPanelY         = 40;               // Initial Panel Y Position
input color            InpHeaderBg       = C'31,78,121';     // Header Background Color (Navy Blue)
input color            InpHeaderTextColor= clrWhite;         // Header Text Color
input color            InpBodyBg         = clrWhite;         // Table Body Background Color
input color            InpBorderColor    = C'200,200,200';   // Table Border Color
input color            InpTextColor      = C'40,40,40';      // General Text Color

//--- Global Variables
string   g_Prefix        = "CBAEA";
int      g_PanelX        = 30;
int      g_PanelY        = 40;
int      g_PanelWidth    = 480;
int      g_PanelHeight   = 320;
int      g_HeaderHeight  = 30;
bool     g_IsCollapsed   = false;
bool     g_IsDragging    = false;
int      g_DragOffsetX   = 0;
int      g_DragOffsetY   = 0;

// Projection lines state
string   g_LineKeys[4]   = {"BullMFE", "BullMAE", "BearMFE", "BearMAE"};
datetime g_PeriodStart   = 0;      // Open time of the current Target-TF bar
datetime g_PeriodEnd     = 0;      // Close time of the current Target-TF bar
datetime g_LastLabelTime = 0;      // Last time position used for text labels
bool     g_StatsReady    = false;  // True once statistics were calculated successfully

// Statistical & Predictive Data Structures
struct StatisticalResult
{
   int    count;
   
   // Historical Statistics
   double mfe_mean;
   double mfe_median;
   double mfe_sd;
   double mae_mean;
   double mae_median;
   double mae_sd;
   
   // Predictive Values
   double pred_mfe_val;
   double pred_mfe_min;
   double pred_mfe_max;
   
   double pred_mae_val;
   double pred_mae_min;
   double pred_mae_max;
};

StatisticalResult g_BullStats;
StatisticalResult g_BearStats;
int               g_TotalBarsAnalyzed = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_PanelX = InpPanelX;
   g_PanelY = InpPanelY;

   // Enable chart mouse movement events for dragging UI
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);

   // Perform Initial Calculation, Draw Panel & Projection Lines
   CalculateStatistics();
   CreateDashboard();
   DrawProjectionLines();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up all UI objects
   ObjectsDeleteAll(0, g_Prefix);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);

   // New Target-TF bar OR statistics not ready yet
   if(currentBarTime != lastBarTime || !g_StatsReady)
   {
      if(CalculateStatistics())
      {
         lastBarTime = currentBarTime;
         DrawProjectionLines();
         UpdateDashboardValues();
      }
   }
   else
   {
      // Keep text labels near the latest chart bar
      UpdateLabelPositions();
   }
}

//+------------------------------------------------------------------+
//| ChartEvent function for interactive panel                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Button Click Event (Collapse / Expand)
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

   // Dragging Logic with Chart Boundaries Enforcement
   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      int mouseX = (int)lparam;
      int mouseY = (int)dparam;
      uint mouseState = (uint)sparam;

      bool leftBtnPressed = ((mouseState & 1) == 1);

      // Check if drag starts on Header
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

      // Dragging active
      if(g_IsDragging && leftBtnPressed)
      {
         int rawX = mouseX - g_DragOffsetX;
         int rawY = mouseY - g_DragOffsetY;

         int chartWidth  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
         int chartHeight = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

         int currentPanelHeight = g_IsCollapsed ? g_HeaderHeight : g_PanelHeight;

         // Clamp panel within visible chart boundaries
         g_PanelX = MathMax(0, MathMin(rawX, chartWidth - g_PanelWidth));
         g_PanelY = MathMax(0, MathMin(rawY, chartHeight - currentPanelHeight));

         RepositionDashboard();
         ChartRedraw(0);
      }

      // Mouse release
      if(!leftBtnPressed && g_IsDragging)
      {
         g_IsDragging = false;
         ChartSetInteger(0, CHART_MOUSE_SCROLL, true);
      }
   }
}

//+------------------------------------------------------------------+
//| Math Helper: Calculate Median                                    |
//+------------------------------------------------------------------+
double CalculateMedian(double &arr[])
{
   int size = ArraySize(arr);
   if(size == 0) return 0.0;

   double temp[];
   ArrayCopy(temp, arr);
   ArraySort(temp);

   if(size % 2 != 0)
      return temp[size / 2];
   else
      return (temp[(size / 2) - 1] + temp[size / 2]) / 2.0;
}

//+------------------------------------------------------------------+
//| Math Helper: Calculate Mean                                      |
//+------------------------------------------------------------------+
double CalculateMean(const double &arr[])
{
   int size = ArraySize(arr);
   if(size == 0) return 0.0;

   double sum = 0.0;
   for(int i = 0; i < size; i++)
      sum += arr[i];

   return sum / size;
}

//+------------------------------------------------------------------+
//| Math Helper: Calculate Standard Deviation                        |
//+------------------------------------------------------------------+
double CalculateStdDev(const double &arr[], const double mean)
{
   int size = ArraySize(arr);
   if(size <= 1) return 0.0;

   double sumSqDiff = 0.0;
   for(int i = 0; i < size; i++)
   {
      double diff = arr[i] - mean;
      sumSqDiff += diff * diff;
   }
   return MathSqrt(sumSqDiff / size);
}

//+------------------------------------------------------------------+
//| Get Unit Divider for Pips / Points (With Auto Detection)         |
//+------------------------------------------------------------------+
double GetUnitDivider()
{
   if(InpUnitType == UNIT_AUTO)
   {
      if(_Digits == 3 || _Digits == 5)
         return _Point * 10.0;
      else
         return _Point;
   }
   else if(InpUnitType == UNIT_PIPS)
   {
      if(_Digits == 3 || _Digits == 5)
         return _Point * 10.0;
      else
         return _Point;
   }
   return _Point;
}

//+------------------------------------------------------------------+
//| Helper to Get Display Unit String                                |
//+------------------------------------------------------------------+
string GetUnitDisplayString()
{
   if(InpUnitType == UNIT_AUTO)
   {
      if(_Digits == 3 || _Digits == 5)
         return "Pips";
      else
         return "Points";
   }
   else if(InpUnitType == UNIT_PIPS)
      return "Pips";

   return "Points";
}

//+------------------------------------------------------------------+
//| Perform Statistical and Predictive Analysis                      |
//+------------------------------------------------------------------+
bool CalculateStatistics()
{
   g_StatsReady = false;

   int availableBars = iBars(_Symbol, InpTimeframe);
   if(availableBars <= 1) return false;

   int fetchCount = 0;
   if(InpCalcMode == MODE_BAR_COUNT)
      fetchCount = MathMin(InpBarCount, availableBars - 1);
   else
      fetchCount = availableBars - 1;

   if(fetchCount <= 0) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpTimeframe, 1, fetchCount, rates);

   if(copied <= 0) return false;

   g_TotalBarsAnalyzed = copied;

   double bull_mfe[], bull_mae[];
   double bear_mfe[], bear_mae[];

   ArrayResize(bull_mfe, 0); ArrayResize(bull_mae, 0);
   ArrayResize(bear_mfe, 0); ArrayResize(bear_mae, 0);

   double unitDivider = GetUnitDivider();
   if(unitDivider == 0) unitDivider = 1.0;

   for(int i = 0; i < copied; i++)
   {
      double open  = rates[i].open;
      double high  = rates[i].high;
      double low   = rates[i].low;
      double close = rates[i].close;

      if(close > open)
      {
         double mfe = (high - open) / unitDivider;
         double mae = (open - low)  / unitDivider;

         int size = ArraySize(bull_mfe);
         ArrayResize(bull_mfe, size + 1);
         ArrayResize(bull_mae, size + 1);
         bull_mfe[size] = mfe;
         bull_mae[size] = mae;
      }
      else if(close < open)
      {
         double mfe = (open - low)  / unitDivider;
         double mae = (high - open) / unitDivider;

         int size = ArraySize(bear_mfe);
         ArrayResize(bear_mfe, size + 1);
         ArrayResize(bear_mae, size + 1);
         bear_mfe[size] = mfe;
         bear_mae[size] = mae;
      }
   }

   // --- Bullish Historical Calculations ---
   g_BullStats.count      = ArraySize(bull_mfe);
   g_BullStats.mfe_mean   = CalculateMean(bull_mfe);
   g_BullStats.mfe_median = CalculateMedian(bull_mfe);
   double raw_bull_mfe_sd = CalculateStdDev(bull_mfe, g_BullStats.mfe_mean);
   g_BullStats.mfe_sd     = raw_bull_mfe_sd * InpSDMultiplier;

   g_BullStats.mae_mean   = CalculateMean(bull_mae);
   g_BullStats.mae_median = CalculateMedian(bull_mae);
   double raw_bull_mae_sd = CalculateStdDev(bull_mae, g_BullStats.mae_mean);
   g_BullStats.mae_sd     = raw_bull_mae_sd * InpSDMultiplier;

   // --- Bullish Predictive Calculations ---
   double bull_mfe_base = g_BullStats.mfe_mean;
   double bull_mae_base = g_BullStats.mae_mean;

   g_BullStats.pred_mfe_val = bull_mfe_base + (raw_bull_mfe_sd * InpPredSDMultiplier);
   g_BullStats.pred_mfe_min = MathMax(0.0, bull_mfe_base - (raw_bull_mfe_sd * InpPredSDMultiplier));
   g_BullStats.pred_mfe_max = bull_mfe_base + (raw_bull_mfe_sd * InpPredSDMultiplier);

   g_BullStats.pred_mae_val = bull_mae_base + (raw_bull_mae_sd * InpPredSDMultiplier);
   g_BullStats.pred_mae_min = MathMax(0.0, bull_mae_base - (raw_bull_mae_sd * InpPredSDMultiplier));
   g_BullStats.pred_mae_max = bull_mae_base + (raw_bull_mae_sd * InpPredSDMultiplier);

   // --- Bearish Historical Calculations ---
   g_BearStats.count      = ArraySize(bear_mfe);
   g_BearStats.mfe_mean   = CalculateMean(bear_mfe);
   g_BearStats.mfe_median = CalculateMedian(bear_mfe);
   double raw_bear_mfe_sd = CalculateStdDev(bear_mfe, g_BearStats.mfe_mean);
   g_BearStats.mfe_sd     = raw_bear_mfe_sd * InpSDMultiplier;

   g_BearStats.mae_mean   = CalculateMean(bear_mae);
   g_BearStats.mae_median = CalculateMedian(bear_mae);
   double raw_bear_mae_sd = CalculateStdDev(bear_mae, g_BearStats.mae_mean);
   g_BearStats.mae_sd     = raw_bear_mae_sd * InpSDMultiplier;

   // --- Bearish Predictive Calculations ---
   double bear_mfe_base = g_BearStats.mfe_mean;
   double bear_mae_base = g_BearStats.mae_mean;

   g_BearStats.pred_mfe_val = bear_mfe_base + (raw_bear_mfe_sd * InpPredSDMultiplier);
   g_BearStats.pred_mfe_min = MathMax(0.0, bear_mfe_base - (raw_bear_mfe_sd * InpPredSDMultiplier));
   g_BearStats.pred_mfe_max = bear_mfe_base + (raw_bear_mfe_sd * InpPredSDMultiplier);

   g_BearStats.pred_mae_val = bear_mae_base + (raw_bear_mae_sd * InpPredSDMultiplier);
   g_BearStats.pred_mae_min = MathMax(0.0, bear_mae_base - (raw_bear_mae_sd * InpPredSDMultiplier));
   g_BearStats.pred_mae_max = bear_mae_base + (raw_bear_mae_sd * InpPredSDMultiplier);

   g_StatsReady = true;
   return true;
}

//+------------------------------------------------------------------+
//| PROJECTION LINES                                                 |
//+------------------------------------------------------------------+
void DeleteProjectionLines()
{
   ObjectsDeleteAll(0, g_Prefix + "Ln_");
   ObjectsDeleteAll(0, g_Prefix + "Lb_");
}

datetime GetLabelTime()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0) + (datetime)(3 * PeriodSeconds(PERIOD_CURRENT));
   if(t > g_PeriodEnd)   t = g_PeriodEnd;
   if(t < g_PeriodStart) t = g_PeriodStart;
   return t;
}

void DrawLevel(const string key, const string title, double price, double valInUnits, const color clr,
               const ENUM_LINE_STYLE style, const datetime labelTime)
{
   price = NormalizeDouble(price, _Digits);

   string lineName  = g_Prefix + "Ln_" + key;
   string labelName = g_Prefix + "Lb_" + key;
   string unitLabel = GetUnitDisplayString();
   
   // Create formatted text containing Title, Price, and Dynamic Pips/Points value
   string caption = StringFormat("%s  %s  (%.1f %s)", title, DoubleToString(price, _Digits), valInUnits, unitLabel);

   // --- Line ---
   ObjectDelete(0, lineName);
   if(InpFullWidthLines)
   {
      ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, price);
   }
   else
   {
      ObjectCreate(0, lineName, OBJ_TREND, 0, g_PeriodStart, price, g_PeriodEnd, price);
      ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, lineName, OBJPROP_RAY_LEFT,  false);
   }

   int width = (style == STYLE_SOLID) ? MathMax(1, InpLineWidth) : 1;

   ObjectSetInteger(0, lineName, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE,      style);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, lineName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
   ObjectSetString(0,  lineName, OBJPROP_TEXT,       caption);
   ObjectSetString(0,  lineName, OBJPROP_TOOLTIP,    caption); // Dynamic hover tooltip

   // --- Label ---
   ObjectDelete(0, labelName);
   if(InpShowLineLabels)
   {
      ObjectCreate(0, labelName, OBJ_TEXT, 0, labelTime, price);
      ObjectSetString(0,  labelName, OBJPROP_TEXT,       caption);
      ObjectSetString(0,  labelName, OBJPROP_FONT,       "Segoe UI");
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE,   8);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR,      clr);
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, labelName, OBJPROP_BACK,       false);
      ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
   }
}

void DrawProjectionLines()
{
   DeleteProjectionLines();
   g_LastLabelTime = 0;

   if(!InpShowLines)
   {
      ChartRedraw(0);
      return;
   }

   g_PeriodStart = iTime(_Symbol, InpTimeframe, 0);
   double open0  = iOpen(_Symbol, InpTimeframe, 0);
   if(g_PeriodStart == 0 || open0 <= 0.0) return;

   g_PeriodEnd = g_PeriodStart + (datetime)PeriodSeconds(InpTimeframe);

   double unit = GetUnitDivider();
   if(unit <= 0.0) unit = _Point;

   datetime labelTime = GetLabelTime();
   g_LastLabelTime    = labelTime;

   // Bullish lines
   if(InpShowBullLines && g_BullStats.count > 0)
   {
      DrawLevel("BullMFE", "Bull MFE", open0 + g_BullStats.pred_mfe_max * unit, g_BullStats.pred_mfe_max, InpBullLineColor, STYLE_SOLID, labelTime);
      DrawLevel("BullMAE", "Bull MAE", open0 - g_BullStats.pred_mae_max * unit, g_BullStats.pred_mae_max, InpBullLineColor, STYLE_DASH,  labelTime);
   }

   // Bearish lines
   if(InpShowBearLines && g_BearStats.count > 0)
   {
      DrawLevel("BearMFE", "Bear MFE", open0 - g_BearStats.pred_mfe_max * unit, g_BearStats.pred_mfe_max, InpBearLineColor, STYLE_SOLID, labelTime);
      DrawLevel("BearMAE", "Bear MAE", open0 + g_BearStats.pred_mae_max * unit, g_BearStats.pred_mae_max, InpBearLineColor, STYLE_DASH,  labelTime);
   }

   ChartRedraw(0);
}

void UpdateLabelPositions()
{
   if(!InpShowLines || !InpShowLineLabels || g_PeriodEnd == 0) return;

   datetime t = GetLabelTime();
   if(t == g_LastLabelTime) return;
   g_LastLabelTime = t;

   for(int i = 0; i < 4; i++)
      ObjectSetInteger(0, g_Prefix + "Lb_" + g_LineKeys[i], OBJPROP_TIME, t);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| GUI Dashboard Creation                                          |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   CreateRectLabel("BgFrame", g_PanelX, g_PanelY, g_PanelWidth, g_PanelHeight, InpBodyBg, InpBorderColor, 1);
   CreateRectLabel("HeaderBg", g_PanelX, g_PanelY, g_PanelWidth, g_HeaderHeight, InpHeaderBg, InpHeaderBg, 0);
   CreateLabel("HeaderTitle", "CANDLE BEHAVIORAL ANALYTICS (v8.20)", g_PanelX + 12, g_PanelY + 6, InpHeaderTextColor, 9, true);
   CreateButton("BtnCollapse", "[-]", g_PanelX + g_PanelWidth - 28, g_PanelY + 4, 22, 20, InpHeaderBg, clrWhite);

   CreateLabel("lblInfo1", "", g_PanelX + 12,  g_PanelY + 35, C'100,100,100', 8, false);
   CreateLabel("lblInfo2", "", g_PanelX + 270, g_PanelY + 35, C'100,100,100', 8, false);

   int startY = g_PanelY + 54;
   CreateRectLabel("TblHeaderBg", g_PanelX + 10, startY, g_PanelWidth - 20, 20, C'240,243,246', C'220,224,230', 1);
   CreateLabel("thGroup", "Historical",   g_PanelX + 15,  startY + 3, C'80,80,80', 8, true);
   CreateLabel("thCount", "Count",        g_PanelX + 85,  startY + 3, C'80,80,80', 8, true);
   CreateLabel("thMFE",   "MFE (Med / Avg / SD)", g_PanelX + 135, startY + 3, C'80,80,80', 8, true);
   CreateLabel("thMAE",   "MAE (Med / Avg / SD)", g_PanelX + 300, startY + 3, C'80,80,80', 8, true);

   int row1Y = startY + 22;
   CreateRectLabel("Row1Bg", g_PanelX + 10, row1Y, g_PanelWidth - 20, 36, clrWhite, C'230,230,230', 1);
   CreateLabel("lblBullTitle", "[+] Bullish", g_PanelX + 15, row1Y + 10, C'0,128,64', 8, true);
   CreateLabel("valBullCount", "0",               g_PanelX + 85, row1Y + 10, InpTextColor, 8, false);
   CreateLabel("valBullMFE",   "0.0 / 0.0 / 0.0", g_PanelX + 135, row1Y + 10, InpTextColor, 8, false);
   CreateLabel("valBullMAE",   "0.0 / 0.0 / 0.0", g_PanelX + 300, row1Y + 10, InpTextColor, 8, false);

   int row2Y = row1Y + 39;
   CreateRectLabel("Row2Bg", g_PanelX + 10, row2Y, g_PanelWidth - 20, 36, clrWhite, C'230,230,230', 1);
   CreateLabel("lblBearTitle", "[-] Bearish", g_PanelX + 15, row2Y + 10, C'192,0,0', 8, true);
   CreateLabel("valBearCount", "0",               g_PanelX + 85, row2Y + 10, InpTextColor, 8, false);
   CreateLabel("valBearMFE",   "0.0 / 0.0 / 0.0", g_PanelX + 135, row2Y + 10, InpTextColor, 8, false);
   CreateLabel("valBearMAE",   "0.0 / 0.0 / 0.0", g_PanelX + 300, row2Y + 10, InpTextColor, 8, false);

   int predStartY = row2Y + 44;
   CreateRectLabel("Tbl2HeaderBg", g_PanelX + 10, predStartY, g_PanelWidth - 20, 20, C'230,238,248', C'200,215,235', 1);
   CreateLabel("th2Group", "Predictive Range",       g_PanelX + 15,  predStartY + 3, C'31,78,121', 8, true);
   CreateLabel("th2MFE",   "Expected MFE [Min - Max]", g_PanelX + 135, predStartY + 3, C'31,78,121', 8, true);
   CreateLabel("th2MAE",   "Exp MAE Limit [Min - Max]",g_PanelX + 300, predStartY + 3, C'31,78,121', 8, true);

   int row3Y = predStartY + 22;
   CreateRectLabel("Row3Bg", g_PanelX + 10, row3Y, g_PanelWidth - 20, 38, clrWhite, C'230,230,230', 1);
   CreateLabel("lblPredBullTitle", "[+] Bull Pred", g_PanelX + 15, row3Y + 11, C'0,128,64', 8, true);
   CreateLabel("valPredBullMFE",   "0.0 [0.0 - 0.0]", g_PanelX + 135, row3Y + 11, InpTextColor, 8, false);
   CreateLabel("valPredBullMAE",   "0.0 [0.0 - 0.0]", g_PanelX + 300, row3Y + 11, InpTextColor, 8, false);

   int row4Y = row3Y + 41;
   CreateRectLabel("Row4Bg", g_PanelX + 10, row4Y, g_PanelWidth - 20, 38, clrWhite, C'230,230,230', 1);
   CreateLabel("lblPredBearTitle", "[-] Bear Pred", g_PanelX + 15, row4Y + 11, C'192,0,0', 8, true);
   CreateLabel("valPredBearMFE",   "0.0 [0.0 - 0.0]", g_PanelX + 135, row4Y + 11, InpTextColor, 8, false);
   CreateLabel("valPredBearMAE",   "0.0 [0.0 - 0.0]", g_PanelX + 300, row4Y + 11, InpTextColor, 8, false);

   CreateLabel("lblFooter", "Engineered by Eng.Alhassan Ali Mubarak Bahbah", g_PanelX + 12, g_PanelY + g_PanelHeight - 16, C'140,140,140', 7, false);

   UpdateDashboardValues();
}

//+------------------------------------------------------------------+
//| Update Dynamic Dashboard Values                                  |
//+------------------------------------------------------------------+
void UpdateDashboardValues()
{
   string unitStr = GetUnitDisplayString();
   string tfStr   = EnumToString(InpTimeframe);
   StringReplace(tfStr, "PERIOD_", "");

   string info1 = StringFormat("TF: %s  |  Bars: %d  |  Unit: %s", tfStr, g_TotalBarsAnalyzed, unitStr);
   string info2 = StringFormat("Base: Mean  |  Pred SD: %.2f", InpPredSDMultiplier);

   ObjectSetString(0, g_Prefix + "lblInfo1", OBJPROP_TEXT, info1);
   ObjectSetString(0, g_Prefix + "lblInfo2", OBJPROP_TEXT, info2);

   ObjectSetString(0, g_Prefix + "valBullCount", OBJPROP_TEXT, IntegerToString(g_BullStats.count));
   ObjectSetString(0, g_Prefix + "valBullMFE",   OBJPROP_TEXT, StringFormat("%.1f / %.1f / %.1f", g_BullStats.mfe_median, g_BullStats.mfe_mean, g_BullStats.mfe_sd));
   ObjectSetString(0, g_Prefix + "valBullMAE",   OBJPROP_TEXT, StringFormat("%.1f / %.1f / %.1f", g_BullStats.mae_median, g_BullStats.mae_mean, g_BullStats.mae_sd));

   ObjectSetString(0, g_Prefix + "valBearCount", OBJPROP_TEXT, IntegerToString(g_BearStats.count));
   ObjectSetString(0, g_Prefix + "valBearMFE",   OBJPROP_TEXT, StringFormat("%.1f / %.1f / %.1f", g_BearStats.mfe_median, g_BearStats.mfe_mean, g_BearStats.mfe_sd));
   ObjectSetString(0, g_Prefix + "valBearMAE",   OBJPROP_TEXT, StringFormat("%.1f / %.1f / %.1f", g_BearStats.mae_median, g_BearStats.mae_mean, g_BearStats.mae_sd));

   ObjectSetString(0, g_Prefix + "valPredBullMFE", OBJPROP_TEXT, StringFormat("%.1f [%.1f - %.1f]", g_BullStats.pred_mfe_val, g_BullStats.pred_mfe_min, g_BullStats.pred_mfe_max));
   ObjectSetString(0, g_Prefix + "valPredBullMAE", OBJPROP_TEXT, StringFormat("%.1f [%.1f - %.1f]", g_BullStats.pred_mae_val, g_BullStats.pred_mae_min, g_BullStats.pred_mae_max));

   ObjectSetString(0, g_Prefix + "valPredBearMFE", OBJPROP_TEXT, StringFormat("%.1f [%.1f - %.1f]", g_BearStats.pred_mfe_val, g_BearStats.pred_mfe_min, g_BearStats.pred_mfe_max));
   ObjectSetString(0, g_Prefix + "valPredBearMAE", OBJPROP_TEXT, StringFormat("%.1f [%.1f - %.1f]", g_BearStats.pred_mae_val, g_BearStats.pred_mae_min, g_BearStats.pred_mae_max));

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Handle Collapsing and Expanding UI Elements                      |
//+------------------------------------------------------------------+
void UpdatePanelVisibility()
{
   long tfVisibility = g_IsCollapsed ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS;

   ObjectSetInteger(0, g_Prefix + "lblInfo1",        OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "lblInfo2",        OBJPROP_TIMEFRAMES, tfVisibility);
   
   ObjectSetInteger(0, g_Prefix + "TblHeaderBg",    OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thGroup",         OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thCount",         OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thMFE",           OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "thMAE",           OBJPROP_TIMEFRAMES, tfVisibility);

   ObjectSetInteger(0, g_Prefix + "Row1Bg",          OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "lblBullTitle",    OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valBullCount",    OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valBullMFE",      OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valBullMAE",      OBJPROP_TIMEFRAMES, tfVisibility);

   ObjectSetInteger(0, g_Prefix + "Row2Bg",          OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "lblBearTitle",    OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valBearCount",    OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valBearMFE",      OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valBearMAE",      OBJPROP_TIMEFRAMES, tfVisibility);

   ObjectSetInteger(0, g_Prefix + "Tbl2HeaderBg",   OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "th2Group",        OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "th2MFE",          OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "th2MAE",          OBJPROP_TIMEFRAMES, tfVisibility);

   ObjectSetInteger(0, g_Prefix + "Row3Bg",          OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "lblPredBullTitle",OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valPredBullMFE",  OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valPredBullMAE",  OBJPROP_TIMEFRAMES, tfVisibility);

   ObjectSetInteger(0, g_Prefix + "Row4Bg",          OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "lblPredBearTitle",OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valPredBearMFE",  OBJPROP_TIMEFRAMES, tfVisibility);
   ObjectSetInteger(0, g_Prefix + "valPredBearMAE",  OBJPROP_TIMEFRAMES, tfVisibility);

   ObjectSetInteger(0, g_Prefix + "lblFooter",       OBJPROP_TIMEFRAMES, tfVisibility);

   int newHeight = g_IsCollapsed ? g_HeaderHeight : g_PanelHeight;
   ObjectSetInteger(0, g_Prefix + "BgFrame", OBJPROP_YSIZE, newHeight);
}

//+------------------------------------------------------------------+
//| Reposition Dashboard Objects during Dragging                     |
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

   ObjectSetInteger(0, g_Prefix + "lblInfo1",    OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblInfo1",    OBJPROP_YDISTANCE, g_PanelY + 35);

   ObjectSetInteger(0, g_Prefix + "lblInfo2",    OBJPROP_XDISTANCE, g_PanelX + 270);
   ObjectSetInteger(0, g_Prefix + "lblInfo2",    OBJPROP_YDISTANCE, g_PanelY + 35);

   int startY = g_PanelY + 54;
   ObjectSetInteger(0, g_Prefix + "TblHeaderBg", OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "TblHeaderBg", OBJPROP_YDISTANCE, startY);
   ObjectSetInteger(0, g_Prefix + "thGroup",     OBJPROP_XDISTANCE, g_PanelX + 15);
   ObjectSetInteger(0, g_Prefix + "thGroup",     OBJPROP_YDISTANCE, startY + 3);
   ObjectSetInteger(0, g_Prefix + "thCount",     OBJPROP_XDISTANCE, g_PanelX + 85);
   ObjectSetInteger(0, g_Prefix + "thCount",     OBJPROP_YDISTANCE, startY + 3);
   ObjectSetInteger(0, g_Prefix + "thMFE",       OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "thMFE",       OBJPROP_YDISTANCE, startY + 3);
   ObjectSetInteger(0, g_Prefix + "thMAE",       OBJPROP_XDISTANCE, g_PanelX + 300);
   ObjectSetInteger(0, g_Prefix + "thMAE",       OBJPROP_YDISTANCE, startY + 3);

   int row1Y = startY + 22;
   ObjectSetInteger(0, g_Prefix + "Row1Bg",       OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "Row1Bg",       OBJPROP_YDISTANCE, row1Y);
   ObjectSetInteger(0, g_Prefix + "lblBullTitle", OBJPROP_XDISTANCE, g_PanelX + 15);
   ObjectSetInteger(0, g_Prefix + "lblBullTitle", OBJPROP_YDISTANCE, row1Y + 10);
   ObjectSetInteger(0, g_Prefix + "valBullCount", OBJPROP_XDISTANCE, g_PanelX + 85);
   ObjectSetInteger(0, g_Prefix + "valBullCount", OBJPROP_YDISTANCE, row1Y + 10);
   ObjectSetInteger(0, g_Prefix + "valBullMFE",   OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "valBullMFE",   OBJPROP_YDISTANCE, row1Y + 10);
   ObjectSetInteger(0, g_Prefix + "valBullMAE",   OBJPROP_XDISTANCE, g_PanelX + 300);
   ObjectSetInteger(0, g_Prefix + "valBullMAE",   OBJPROP_YDISTANCE, row1Y + 10);

   int row2Y = row1Y + 39;
   ObjectSetInteger(0, g_Prefix + "Row2Bg",       OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "Row2Bg",       OBJPROP_YDISTANCE, row2Y);
   ObjectSetInteger(0, g_Prefix + "lblBearTitle", OBJPROP_XDISTANCE, g_PanelX + 15);
   ObjectSetInteger(0, g_Prefix + "lblBearTitle", OBJPROP_YDISTANCE, row2Y + 10);
   ObjectSetInteger(0, g_Prefix + "valBearCount", OBJPROP_XDISTANCE, g_PanelX + 85);
   ObjectSetInteger(0, g_Prefix + "valBearCount", OBJPROP_YDISTANCE, row2Y + 10);
   ObjectSetInteger(0, g_Prefix + "valBearMFE",   OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "valBearMFE",   OBJPROP_YDISTANCE, row2Y + 10);
   ObjectSetInteger(0, g_Prefix + "valBearMAE",   OBJPROP_XDISTANCE, g_PanelX + 300);
   ObjectSetInteger(0, g_Prefix + "valBearMAE",   OBJPROP_YDISTANCE, row2Y + 10);

   int predStartY = row2Y + 44;
   ObjectSetInteger(0, g_Prefix + "Tbl2HeaderBg",OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "Tbl2HeaderBg",OBJPROP_YDISTANCE, predStartY);
   ObjectSetInteger(0, g_Prefix + "th2Group",     OBJPROP_XDISTANCE, g_PanelX + 15);
   ObjectSetInteger(0, g_Prefix + "th2Group",     OBJPROP_YDISTANCE, predStartY + 3);
   ObjectSetInteger(0, g_Prefix + "th2MFE",       OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "th2MFE",       OBJPROP_YDISTANCE, predStartY + 3);
   ObjectSetInteger(0, g_Prefix + "th2MAE",       OBJPROP_XDISTANCE, g_PanelX + 300);
   ObjectSetInteger(0, g_Prefix + "th2MAE",       OBJPROP_YDISTANCE, predStartY + 3);

   int row3Y = predStartY + 22;
   ObjectSetInteger(0, g_Prefix + "Row3Bg",          OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "Row3Bg",          OBJPROP_YDISTANCE, row3Y);
   ObjectSetInteger(0, g_Prefix + "lblPredBullTitle",OBJPROP_XDISTANCE, g_PanelX + 15);
   ObjectSetInteger(0, g_Prefix + "lblPredBullTitle",OBJPROP_YDISTANCE, row3Y + 11);
   ObjectSetInteger(0, g_Prefix + "valPredBullMFE",  OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "valPredBullMFE",  OBJPROP_YDISTANCE, row3Y + 11);
   ObjectSetInteger(0, g_Prefix + "valPredBullMAE",  OBJPROP_XDISTANCE, g_PanelX + 300);
   ObjectSetInteger(0, g_Prefix + "valPredBullMAE",  OBJPROP_YDISTANCE, row3Y + 11);

   int row4Y = row3Y + 41;
   ObjectSetInteger(0, g_Prefix + "Row4Bg",          OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "Row4Bg",          OBJPROP_YDISTANCE, row4Y);
   ObjectSetInteger(0, g_Prefix + "lblPredBearTitle",OBJPROP_XDISTANCE, g_PanelX + 15);
   ObjectSetInteger(0, g_Prefix + "lblPredBearTitle",OBJPROP_YDISTANCE, row4Y + 11);
   ObjectSetInteger(0, g_Prefix + "valPredBearMFE",  OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "valPredBearMFE",  OBJPROP_YDISTANCE, row4Y + 11);
   ObjectSetInteger(0, g_Prefix + "valPredBearMAE",  OBJPROP_XDISTANCE, g_PanelX + 300);
   ObjectSetInteger(0, g_Prefix + "valPredBearMAE",  OBJPROP_YDISTANCE, row4Y + 11);

   ObjectSetInteger(0, g_Prefix + "lblFooter",       OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblFooter",       OBJPROP_YDISTANCE, g_PanelY + g_PanelHeight - 16);
}

//+------------------------------------------------------------------+
//| Helpers to Create Chart Objects                                  |
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
   ObjectSetInteger(0, objName, OBJPROP_BACK, false);
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