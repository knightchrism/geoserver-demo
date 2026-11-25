<?xml version="1.0" encoding="UTF-8"?>
<StyledLayerDescriptor version="1.0.0"
  xmlns="http://www.opengis.net/sld"
  xmlns:ogc="http://www.opengis.net/ogc"
  xmlns:xlink="http://www.w3.org/1999/xlink"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.opengis.net/sld http://schemas.opengis.net/sld/1.0.0/StyledLayerDescriptor.xsd">
  <NamedLayer>
    <Name>dem</Name>
    <UserStyle>
      <Title>Coastal elevation ramp</Title>
      <Abstract>Meters for the Jacksonville 3DEP window. Nodata is -999999 and stays transparent. Colored ground runs from about -3 m to 19 m.</Abstract>
      <FeatureTypeStyle>
        <Rule>
          <RasterSymbolizer>
            <Opacity>1.0</Opacity>
            <ColorMap type="ramp">
              <ColorMapEntry color="#000000" quantity="-999999" opacity="0" label="nodata"/>
              <ColorMapEntry color="#16324f" quantity="-3" opacity="0" label="nodata edge"/>
              <ColorMapEntry color="#16324f" quantity="-2.5" label="below"/>
              <ColorMapEntry color="#1f6f8a" quantity="0" label="sea level"/>
              <ColorMapEntry color="#2f6f4e" quantity="3" label="low"/>
              <ColorMapEntry color="#7d9a3a" quantity="7" label=""/>
              <ColorMapEntry color="#c9a227" quantity="11" label=""/>
              <ColorMapEntry color="#a86432" quantity="15" label=""/>
              <ColorMapEntry color="#f4efe2" quantity="19" label="higher ground"/>
            </ColorMap>
          </RasterSymbolizer>
        </Rule>
      </FeatureTypeStyle>
    </UserStyle>
  </NamedLayer>
</StyledLayerDescriptor>
